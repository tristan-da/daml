-- Copyright (c) 2019 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE OverloadedStrings #-}
module DAML.Assistant.Install
    ( InstallOptions (..)
    , InstallURL (..)
    , installExtracted
    , extractAndInstall
    , httpInstall
    , pathInstall
    , targetInstallURL
    , defaultInstallURL
    , install
    ) where

import DAML.Assistant.Types
import DAML.Assistant.Consts
import DAML.Assistant.Util
import DAML.Assistant.Config
import Conduit
import qualified Data.Conduit.List as List
import qualified Data.Conduit.Tar as Tar
import qualified Data.Conduit.Zlib as Zlib
import Network.HTTP.Simple
import qualified Data.ByteString as BS
import Data.List.Extra
import System.IO.Temp
import System.FilePath
import System.Directory
import Control.Monad.Extra
import Control.Exception.Safe
import System.Posix.Types
import System.Posix.Files -- forget windows for now
import qualified System.Info
import qualified Data.Text as T

displayInstallTarget :: InstallTarget -> Text
displayInstallTarget = \case
    InstallChannel (SdkChannel c) -> "channel " <> c
    InstallVersion (SdkVersion v) -> "version " <> v
    InstallPath p -> pack p

versionMatchesTarget :: SdkVersion -> InstallTarget -> Bool
versionMatchesTarget version = \case
    InstallChannel c -> c == fst (splitVersion version)
    InstallVersion v -> v == version
    InstallPath _ -> True -- tarball path could be any version

newtype InstallURL = InstallURL { unwrapInstallURL :: Text }

data SdkChannelInfo = SdkChannelInfo
    { channelName       :: SdkChannel
    , channelLatestURL  :: InstallURL
    , channelVersionURL :: SdkSubVersion -> InstallURL
    }

knownChannels :: [SdkChannelInfo]
knownChannels =
    [ SdkChannelInfo
        { channelName = SdkChannel "nightly"
        , channelLatestURL  = bintrayLatestURL
        , channelVersionURL = bintrayVersionURL
        }
    ]

lookupChannel :: SdkChannel -> [SdkChannelInfo] -> Maybe SdkChannelInfo
lookupChannel ch = find ((== ch) . channelName)

targetInstallURL :: InstallTarget -> Maybe InstallURL
targetInstallURL = \case
    InstallChannel ch -> channelLatestURL <$> lookupChannel ch knownChannels
    InstallVersion v | (ch, sv) <- splitVersion v ->
        flip channelVersionURL sv <$> lookupChannel ch knownChannels
    InstallPath _ -> Nothing

defaultInstallURL :: InstallURL
defaultInstallURL = bintrayLatestURL

osName :: Text
osName = case System.Info.os of
    "darwin"  -> "osx"
    "linux"   -> "linux"
    "mingw32" -> "win"
    p -> error ("daml: Unknown operating system " ++ p)


bintrayVersionURL :: SdkSubVersion -> InstallURL
bintrayVersionURL (SdkSubVersion subVersion) = InstallURL $ T.concat
    [ "https://bintray.com/api/v1/content"  -- api call
    , "/digitalassetsdk/DigitalAssetSDK"    -- repo/subject
    , "/com/digitalasset/sdk-tarball/"      -- file path
    , subVersion
    , "/sdk-tarball-"
    , subVersion
    , "-"
    , osName
    , ".tar.gz"
    , "?bt_package=sdk-components"          -- package
    ]

bintrayLatestURL :: InstallURL
bintrayLatestURL = bintrayVersionURL (SdkSubVersion "$latest")

-- | Install (extracted) SDK directory to the correct place, after performing
-- a version sanity check. Then run the sdk install hook if applicable.
installExtracted :: InstallOptions -> DamlPath -> SdkPath -> IO ()
installExtracted InstallOptions{..} damlPath sourcePath =
    wrapErr "Installing extracted SDK tarball." $ do
        sourceConfig <- readSdkConfig sourcePath
        sourceVersion <- fromRightM throwIO (sdkVersionFromSdkConfig sourceConfig)


        whenJust iTargetM $ \target ->
            unless (versionMatchesTarget sourceVersion target) $
                throwIO (assistantErrorBecause "SDK release version mismatch."
                    ("Expected " <> displayInstallTarget target
                    <> " but got version " <> unwrapSdkVersion sourceVersion))

        -- Set file mode of files to install.
        requiredIO "Failed to set file modes for extracted SDK files." $
            walkRecursive (unwrapSdkPath sourcePath) WalkCallbacks
                { walkOnFile = setSdkFileMode
                , walkOnDirectoryPost = \path ->
                    when (path /= addTrailingPathSeparator (unwrapSdkPath sourcePath)) $
                        setSdkFileMode path
                , walkOnDirectoryPre = \_ -> pure ()
                }

        let targetPath = defaultSdkPath damlPath sourceVersion
        when (sourcePath /= targetPath) $ do -- should be true 99.9% of the time,
                                            -- but in that 0.1% this check prevents us
                                            -- from deleting the sdk we want to install
                                            -- just because it's already in the right place.
            requiredIO "Failed to remove existing SDK installation." $
                removePathForcibly (unwrapSdkPath targetPath)
                -- Always removePathForcibly to uniformize renameDirectory behavior
                -- between windows and unices. (This is the wrong place for a --force check.
                -- That should occur before downloading or extracting any tarball.)
            requiredIO "Failed to move extracted SDK release to final location." $
                renameDirectory (unwrapSdkPath sourcePath) (unwrapSdkPath targetPath)

        requiredIO "Failed to set file mode of installed SDK directory." $
            setSdkFileMode (unwrapSdkPath targetPath)

        when iActivate $ do
            let damlBinarySourcePath = unwrapSdkPath targetPath </> "daml" </> "daml"
                damlBinaryTargetDir  = unwrapDamlPath damlPath </> "bin"
                damlBinaryTargetPath = damlBinaryTargetDir </> "daml"

            unlessM (doesFileExist damlBinarySourcePath) $
                throwIO $ assistantErrorBecause
                    "daml binary is missing from SDK release."
                    ("expected path = " <> pack damlBinarySourcePath)

            whenM (doesFileExist damlBinaryTargetPath) $
                requiredIO "Failed to delete existing daml binary symbolic link." $
                    removeLink damlBinaryTargetPath

            requiredIO ("Failed to link daml binary in " <> pack damlBinaryTargetDir) $
                createSymbolicLink damlBinarySourcePath damlBinaryTargetPath

            unless iQuiet $ do -- Ask user to add .daml/bin to PATH if it is absent.
                searchPaths <- map dropTrailingPathSeparator <$> getSearchPath
                when (damlBinaryTargetDir `notElem` searchPaths) $ do
                    putStrLn ("Please add " <> damlBinaryTargetDir <> " to your PATH.")

data WalkCallbacks = WalkCallbacks
    { walkOnFile :: FilePath -> IO ()
        -- ^ Callback to be called on files.
    , walkOnDirectoryPre  :: FilePath -> IO ()
        -- ^ Callback to be called on directories before recursion.
    , walkOnDirectoryPost :: FilePath -> IO ()
        -- ^ Callback to be called on directories after recursion.
    }

-- | Walk directory tree recursively, calling the callbacks specified in
-- the WalkCallbacks record. Each callback path is prefixed with the
-- query path. Directory callback paths have trailing path separator.
--
-- Edge case: If walkRecursive is called on a non-existant path, it will
-- call the walkOnFile callback.
walkRecursive :: FilePath -> WalkCallbacks -> IO ()
walkRecursive path callbacks = do
    isDirectory <- doesDirectoryExist path
    if isDirectory
        then do
            let dirPath = addTrailingPathSeparator path -- for uniformity
            walkOnDirectoryPre callbacks dirPath
            children <- listDirectory dirPath
            forM_ children $ \child -> do
                walkRecursive (dirPath </> child) callbacks
            walkOnDirectoryPost callbacks dirPath
        else do
            walkOnFile callbacks path

-- | Restrict file modes of installed sdk files to read and execute.
setSdkFileMode :: FilePath -> IO ()
setSdkFileMode path = do
    sourceMode <- fileMode <$> getFileStatus path
    setFileMode path (intersectFileModes fileModeMask sourceMode)

-- | File mode mask to be applied to installed SDK files.
fileModeMask :: FileMode
fileModeMask = foldl1 unionFileModes
    [ ownerReadMode
    , ownerExecuteMode
    , groupReadMode
    , groupExecuteMode
    , otherReadMode
    , otherExecuteMode
    ]

-- | Copy an extracted SDK release directory and install it.
copyAndInstall :: InstallOptions -> DamlPath -> FilePath -> IO ()
copyAndInstall options damlPath sourcePath =
    wrapErr "Copying SDK release directory." $ do
        withSystemTempDirectory "daml-update" $ \tmp -> do
            let copyPath = tmp </> "release"
                prefixLen = length (addTrailingPathSeparator sourcePath)
                newPath path = copyPath </> drop prefixLen path

            walkRecursive sourcePath WalkCallbacks
                { walkOnFile = \path -> copyFileWithMetadata path (newPath path)
                , walkOnDirectoryPre = \path -> createDirectory (newPath path)
                , walkOnDirectoryPost = \_ -> pure ()
                }

            installExtracted options damlPath (SdkPath copyPath)

type ExtractM = ResourceT IO

-- | Extract a tarGz bytestring and install it.
extractAndInstall :: InstallOptions -> DamlPath -> ConduitT () BS.ByteString ExtractM () -> IO ()
extractAndInstall options damlPath source =
    wrapErr "Extracting SDK release tarball." $ do
        withSystemTempDirectory "daml-update" $ \tmp -> do
            let extractPath = tmp </> "release"
            createDirectory extractPath
            filesAndModes <- runConduitRes
                $ source
                .| Zlib.ungzip
                .| Tar.untar (restoreFile extractPath)
                .| List.consume
            forM_ filesAndModes (uncurry setFileMode)
            installExtracted options damlPath (SdkPath extractPath)
    where
        restoreFile :: FilePath -> Tar.FileInfo
            -> ConduitT BS.ByteString (FilePath, FileMode) ExtractM ()
        restoreFile extractPath info = do
            let oldPath = Tar.decodeFilePath (Tar.filePath info)
                newPath = stripPath oldPath
                targetPath = extractPath </> dropTrailingPathSeparator newPath
                parentPath = takeDirectory targetPath

            when (notNull newPath) $ do
                case Tar.fileType info of
                    Tar.FTNormal -> do
                        liftIO $ createDirectoryIfMissing True parentPath
                        sinkFileBS targetPath >> yield (targetPath, Tar.fileMode info)
                    Tar.FTDirectory -> do
                        liftIO $ createDirectoryIfMissing True targetPath
                    unsupported  ->
                        liftIO $ throwIO $ assistantErrorBecause
                            "Invalid SDK release: unsupported file type."
                            ("type = " <> pack (show unsupported) <>  ", path = " <> pack oldPath)

        -- | strip first component from path
        stripPath :: FilePath -> FilePath
        stripPath = joinPath . tail . splitPath

-- | Download an sdk tarball and install it.
httpInstall :: InstallOptions -> DamlPath -> InstallURL -> IO ()
httpInstall options@InstallOptions{..} damlPath (InstallURL url) = do
    unless iQuiet $ putStrLn "Downloading SDK release."
    request <- parseRequest ("GET " <> unpack url)
    withResponse request $ \response -> do
        when (getResponseStatusCode response /= 200) $
            throwIO . assistantErrorBecause "Failed to download release."
                    . pack . show $ getResponseStatus response
        extractAndInstall options damlPath (getResponseBody response)

-- | Install SDK from a path. If the path is a tarball, extract it first.
pathInstall :: InstallOptions -> DamlPath -> FilePath -> IO ()
pathInstall options@InstallOptions{..} damlPath sourcePath = do
    isDirectory <- doesDirectoryExist sourcePath
    if isDirectory
        then do
            unless iQuiet $ putStrLn "Installing SDK release from directory."
            copyAndInstall options damlPath sourcePath
        else do
            unless iQuiet $ putStrLn "Installing SDK release from tarball."
            extractAndInstall options damlPath (sourceFileBS sourcePath)

-- | Set up initial .daml directory.
initialInstall :: InstallOptions -> DamlPath -> IO ()
initialInstall InstallOptions{..} (DamlPath damlPath) = do
    whenM (doesDirectoryExist damlPath) $ do
        unless iForce $ do
            throwIO $ assistantErrorBecause
                ("DAML home directory " <> pack damlPath <> " already exists. "
                    <> "Please remove it or use --force to continue.")
                ("path = " <> pack damlPath)
    createDirectoryIfMissing True (damlPath </> "bin")
    createDirectoryIfMissing True (damlPath </> "sdk")
    -- For now, we only ensure that the file exists.
    appendFile (damlPath </> damlConfigName) ""

-- | Run install command.
install :: InstallOptions -> DamlPath -> IO ()
install options damlPath = do
    when (iInitial options) $ do
        initialInstall options damlPath

    case iTargetM options of
        Nothing ->
            httpInstall options damlPath defaultInstallURL

        Just (InstallPath tarballPath) ->
            pathInstall options damlPath tarballPath

        Just (InstallChannel channel) -> do
            channelInfo <- required ("Unknown channel " <> unwrapSdkChannel channel) $
                lookupChannel channel knownChannels
            httpInstall options damlPath (channelLatestURL channelInfo)

        Just (InstallVersion version) -> do
            let (channel, subVersion) = splitVersion version
            channelInfo <- required ("Unknown channel " <> unwrapSdkChannel channel) $
                lookupChannel channel knownChannels
            httpInstall options damlPath (channelVersionURL channelInfo subVersion)
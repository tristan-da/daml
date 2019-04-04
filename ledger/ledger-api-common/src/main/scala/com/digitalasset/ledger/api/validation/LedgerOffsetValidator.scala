// Copyright (c) 2019 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.digitalasset.ledger.api.validation
import com.digitalasset.ledger.api.domain
import com.digitalasset.ledger.api.v1.ledger_offset.LedgerOffset
import com.digitalasset.ledger.api.v1.ledger_offset.LedgerOffset.LedgerBoundary
import com.digitalasset.platform.server.api.validation.ErrorFactories.{
  invalidArgument,
  missingField
}
import com.digitalasset.platform.server.api.validation.FieldValidations.requireNonEmptyString
import io.grpc.StatusRuntimeException

object LedgerOffsetValidator {

  private val boundary = "boundary"

  def validate(
      ledgerOffset: LedgerOffset,
      fieldName: String): Either[StatusRuntimeException, domain.LedgerOffset] = {
    ledgerOffset match {
      case LedgerOffset(LedgerOffset.Value.Absolute(value)) =>
        requireNonEmptyString(value, fieldName).map(_ => domain.LedgerOffset.Absolute(value))
      case LedgerOffset(LedgerOffset.Value.Boundary(value)) =>
        convertLedgerBoundary(fieldName, value)
      case LedgerOffset(LedgerOffset.Value.Empty) =>
        Left(missingField(fieldName + ".(" + boundary + "|value)"))
    }
  }

  private def convertLedgerBoundary(
      fieldName: String,
      value: LedgerBoundary): Either[StatusRuntimeException, domain.LedgerOffset] = {
    value match {
      case LedgerBoundary.Unrecognized(invalid) =>
        Left(
          invalidArgument(
            s"Unknown ledger $boundary value '$invalid' in field $fieldName.$boundary"))
      case LedgerBoundary.LEDGER_BEGIN => Right(domain.LedgerOffset.LedgerBegin)
      case LedgerBoundary.LEDGER_END => Right(domain.LedgerOffset.LedgerEnd)
    }
  }
}
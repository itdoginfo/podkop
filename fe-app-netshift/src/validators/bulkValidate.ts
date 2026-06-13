import { BulkValidationResult, ValidationResult } from './types';

export function bulkValidate<T>(
  values: T[],
  validate: (value: T) => ValidationResult,
): BulkValidationResult<T> {
  const results = values.map((value) => ({ ...validate(value), value }));

  return {
    valid: results.every((r) => r.valid),
    results,
  };
}

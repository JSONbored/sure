uploaded = local_assigns[:uploaded]
uploaded = import.uploaded? if uploaded.nil?
configured = local_assigns[:configured]
configured = import.is_a?(SureImport) ? uploaded : import.configured? if configured.nil?

json.uploaded uploaded
json.configured configured
json.terminal import.complete? || import.failed? || import.revert_failed?
json.rows_count import.rows_count

if include_validation_stats
  valid_rows_count = local_assigns[:valid_rows_count]
  invalid_rows_count = local_assigns[:invalid_rows_count]

  if valid_rows_count.nil? || invalid_rows_count.nil?
    rows = import.rows.to_a
    valid_rows_count = rows.count(&:valid?)
    invalid_rows_count = rows.length - valid_rows_count
  end

  cleaned = local_assigns[:cleaned]
  publishable = local_assigns[:publishable]
  cleaned = import.cleaned_from_validation_stats?(invalid_rows_count: invalid_rows_count) if cleaned.nil?
  publishable = import.publishable_from_validation_stats?(invalid_rows_count: invalid_rows_count) if publishable.nil?

  json.cleaned cleaned
  json.publishable publishable
  json.revertable import.revertable?
  json.valid_rows_count valid_rows_count
  json.invalid_rows_count invalid_rows_count
  json.mappings_count import.mappings.count
  json.unassigned_mappings_count import.mappings.where(mappable_id: nil).count
end

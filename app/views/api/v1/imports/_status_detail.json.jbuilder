json.uploaded import.uploaded?
json.configured import.configured?
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

  json.cleaned import.cleaned?
  json.publishable import.publishable?
  json.revertable import.revertable?
  json.valid_rows_count valid_rows_count
  json.invalid_rows_count invalid_rows_count
  json.mappings_count import.mappings.count
  json.unassigned_mappings_count import.mappings.where(mappable_id: nil).count
end

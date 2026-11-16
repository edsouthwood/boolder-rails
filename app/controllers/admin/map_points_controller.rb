# Upload a KML file of map points (folders of named pins): preview where each one goes, then
# apply. Super admins only, as one file can create areas and parking spots. See MapPointsImport.
class Admin::MapPointsController < Admin::BaseController
  before_action :require_super_admin

  def new
  end

  def preview
    @text = submitted_text
    return redirect_to(admin_new_map_points_path, flash: { error: @error }) if @error

    @import = build_import(@text)
    if @import.parsed.folders.empty?
      redirect_to admin_new_map_points_path, flash: { error: "No named points found in that file." }
    end
  rescue MapPointsImport::ParseError => e
    redirect_to admin_new_map_points_path, flash: { error: e.message }
  end

  def create
    # "Update preview" posts here too (the form's CSRF token is tied to this action)
    return preview_again if params[:update_preview].present?

    import = build_import(params[:text].to_s.first(MapPointsImport::MAX_BYTES))
    summary = import.apply!(
      choices: hash_param(:choices), names: hash_param(:names),
      adopt: Array(params[:adopt]), replace: Array(params[:replace]),
      parking: params[:parking_sent] ? Array(params[:parking]) : nil)
    redirect_to admin_areas_path, notice: summary_text(summary)
  rescue MapPointsImport::ParseError => e
    redirect_to admin_new_map_points_path, flash: { error: e.message }
  rescue ActiveRecord::RecordInvalid => e
    redirect_to admin_new_map_points_path, flash: { error: "Nothing was imported: #{e.record.errors.full_messages.to_sentence}" }
  end

  private

  def preview_again
    @text = params[:text].to_s.first(MapPointsImport::MAX_BYTES)
    @import = build_import(@text)
    render :preview
  rescue MapPointsImport::ParseError => e
    redirect_to admin_new_map_points_path, flash: { error: e.message }
  end

  def build_import(text)
    MapPointsImport.new(text, targets: hash_param(:targets), area_names: hash_param(:area_names))
  end

  def hash_param(key)
    value = params[key]
    value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h.transform_values(&:to_s) : {}
  end

  def submitted_text
    file = params[:file]
    text = file.respond_to?(:read) ? file.read(MapPointsImport::MAX_BYTES + 1).to_s : params[:text].to_s
    text = text.dup.force_encoding("UTF-8")
    @error = "That's more than #{MapPointsImport::MAX_BYTES / 1.megabyte} MB; split the map up." if text.bytesize > MapPointsImport::MAX_BYTES
    @error ||= "Choose a KML file first." if text.strip.empty?
    @error ||= "The file isn't readable text. Export the map as KML." unless text.start_with?("PK") || text.valid_encoding?
    text
  end

  def summary_text(summary)
    parts = {
      areas_created: [ "area created (unpublished)", "areas created (unpublished)" ],
      boulders_created: [ "boulder name added", "boulder names added" ],
      located: [ "boulder given a location", "boulders given a location" ],
      outlines_named: [ "outline named", "outlines named" ],
      location_kept: [ "saved location kept", "saved locations kept" ],
      parking_created: [ "parking spot added", "parking spots added" ],
      skipped: [ "point skipped", "points skipped" ]
    }.filter_map do |key, (one, many)|
      count = summary[key]
      "#{count} #{count == 1 ? one : many}" if count.positive?
    end
    parts.any? ? "Imported: #{parts.to_sentence}." : "Nothing to change."
  end
end

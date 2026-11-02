# Paste a crag list (boulder names, each followed by its problems and grades) into an area:
# preview what it would change, then apply. See CragListImport.
class Admin::ProblemListsController < Admin::BaseController
  before_action :set_area_and_check_access

  MAX_TEXT = 200.kilobytes

  def new
  end

  def preview
    @text = submitted_text
    return redirect_to(admin_area_problem_list_path(area_slug: @area.slug), flash: { error: @error }) if @error

    @import = CragListImport.new(@area, @text)
    if @import.parsed.sections.empty?
      redirect_to admin_area_problem_list_path(area_slug: @area.slug),
        flash: { error: "No boulder names found. Each boulder's name goes on its own line, followed by its problems." }
    end
  end

  def create
    import = CragListImport.new(@area, params[:text].to_s.first(MAX_TEXT))
    summary = import.apply!(choices: params.fetch(:choices, {}).to_unsafe_h, update_grades: Array(params[:update_grades]))
    redirect_to admin_area_boulders_path(area_slug: @area.slug), notice: summary_text(summary)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to admin_area_problem_list_path(area_slug: @area.slug), flash: { error: "Nothing was imported: #{e.record.errors.full_messages.to_sentence}" }
  end

  private

  def set_area_and_check_access
    @area = Area.find_by!(slug: params[:area_slug])
    require_area_access(@area.slug)
  end

  def submitted_text
    file = params[:file]
    text = if file.respond_to?(:read)
      file.read(MAX_TEXT + 1).to_s.force_encoding("UTF-8")
    else
      params[:text].to_s
    end
    @error = "That's more than #{MAX_TEXT / 1.kilobyte} KB; split the list up." if text.bytesize > MAX_TEXT
    @error ||= "The file isn't readable text (save it as UTF-8)." unless text.valid_encoding?
    @error ||= "Paste a list or choose a file first." if text.strip.empty?
    text.delete_prefix("﻿")
  end

  def summary_text(summary)
    parts = {
      boulders_created: [ "boulder", "boulders" ],
      outlines_named: [ "outline named", "outlines named" ],
      problems_created: [ "new problem", "new problems" ],
      assigned: [ "problem put on a boulder", "problems put on a boulder" ],
      moved: [ "problem moved to another boulder", "problems moved to another boulder" ],
      grades_updated: [ "grade updated", "grades updated" ],
      skipped: [ "row skipped", "rows skipped" ]
    }.filter_map do |key, (one, many)|
      count = summary[key]
      "#{count} #{count == 1 ? one : many}" if count.positive?
    end
    parts.any? ? "Imported: #{parts.to_sentence}." : "Nothing to change: the list already matches."
  end
end

require "csv"

# Open-data export, released under CC0 (public domain): every publicly visible
# problem as a single CSV. Linked from the About page and the footer.
class OpenDataController < ApplicationController
  CSV_COLUMNS = %w[id name grade steepness latitude longitude area url].freeze

  def problems
    # Visibility mirrors Problem#published?: a published area and a location.
    problems = Problem.joins(:area).where(areas: { published: true }).where.not(location: nil).
      includes(:area).order(:id)

    return unless stale?(etag: [ problems.maximum(:updated_at), problems.size ], public: true)

    csv = CSV.generate(headers: CSV_COLUMNS, write_headers: true) do |rows|
      problems.each do |problem|
        rows << [
          problem.id, problem.name, problem.grade, problem.steepness,
          problem.lat, problem.lon, problem.area.name,
          problem_permalink_url(id: problem.id, locale: :en)
        ]
      end
    end

    send_data csv, filename: "bowda-dartmoor-problems-#{Date.current.iso8601}.csv",
                   type: "text/csv; charset=utf-8"
  end
end

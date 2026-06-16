module Areas
  class OfflineDataController < ApplicationController
    def show
      area = Area.find_by!(slug: params[:slug])

      topo_ids = Topo.published
        .joins(lines: :problem)
        .where(problems: { area_id: area.id })
        .distinct
        .pluck(:id)

      topos = Topo.where(id: topo_ids)

      # Canonical problem pages shown on the map, so tapping a problem works offline.
      problems = area.problems.with_location
      problem_urls = problems.map { |problem| area_problem_path(area, problem) }

      sw = area.serialized_bounds[:south_west]
      ne = area.serialized_bounds[:north_east]

      render json: {
        slug: area.slug,
        name: area.name,
        topo_count: topos.count,
        topo_urls: topos.map { |topo| topo_proxy_url(topo, locale: nil) },
        problem_urls: problem_urls,
        # Bounds and map URLs let the client pre-download the base map tiles and
        # overlay data covering this area for offline use (see offline_download_controller.js).
        bounds: {
          southWestLat: sw[:lat], southWestLon: sw[:lng],
          northEastLat: ne[:lat], northEastLon: ne[:lng]
        },
        map_url: map_path(area),
        # Exact URLs the area map page requests, so cached entries match live requests.
        map_data_url: map_data_path(format: :geojson),
        area_labels_url: area_labels_path(format: :geojson)
      }
    end
  end
end

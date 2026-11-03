namespace :problems do
  desc "Give unlocated problems that are on a photo an estimated location from it. Dry run unless APPLY=1; AREA=slug limits it to one area"
  task estimate_locations: :environment do
    apply = ENV["APPLY"] == "1"
    problems = Problem.without_location.where(id: Line.select(:problem_id)).includes(:area, lines: :topo).order(:area_id, :id)
    problems = problems.where(area: Area.find_by!(slug: ENV["AREA"])) if ENV["AREA"].present?

    located = 0
    problems.each do |problem|
      topos = problem.lines.sort_by { |l| [ l.coordinates ? 0 : 1, l.id ] }.filter_map(&:topo).uniq
      topo, point = topos.lazy.filter_map { |t| (p = t.estimated_location_for(problem)) && [ t, p ] }.first
      label = "#{problem.area&.slug} ##{problem.id} #{problem.name_with_fallback}"

      if point.nil?
        puts "  skip  #{label}: none of its photos has GPS or a placed problem to go on"
      else
        topo.estimate_location!(problem) if apply
        located += 1
        puts "  #{apply ? "placed" : "would place"} #{label} from topo ##{topo.id} at #{point.lat.round(6)}, #{point.lon.round(6)}"
      end
    end

    puts "#{apply ? "Placed" : "Would place"} #{located} of #{problems.size} problems (marked estimated).#{" Run with APPLY=1 to save." unless apply}"
  end
end

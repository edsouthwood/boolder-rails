namespace :topos do
  desc "Show portrait photos stored cropped to 4:3 whole, moving their lines to match (see TopoUncropper). Dry run unless APPLY=1; TOPO=id does one"
  task uncrop_portraits: :environment do
    apply = ENV["APPLY"] == "1"
    topos = ENV["TOPO"].present? ? Topo.where(id: ENV["TOPO"]) : TopoUncropper.candidates

    topos.each do |topo|
      r = TopoUncropper.new(topo, dry_run: !apply).call
      new_part = r.new_topo ? " → topo ##{r.new_topo.id}" : ""
      puts "  #{r.status.to_s.tr("_", " ")}  topo ##{topo.id}#{new_part}: #{r.message}"
    rescue => e
      # One that fails is rolled back and left as it was; carry on with the rest
      puts "  FAILED  topo ##{topo.id}: #{e.class}: #{e.message}"
    end

    puts "#{topos.size} topo(s) looked at.#{" Run with APPLY=1 to convert." unless apply}"
  end
end

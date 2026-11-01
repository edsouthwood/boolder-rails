namespace :geo do
  # Full rebuild of topos.boulder_id / position. Normally not needed: saving a boulder,
  # problem location, line or topo recomputes the affected boulders automatically.
  task compute: :environment do
    Topo.update_all(boulder_id: nil, position: nil)

    Boulder.find_each do |boulder|
      boulder.recompute_topos!
      puts "Boulder ##{boulder.id}: #{Topo.where(boulder_id: boulder.id).count} topos linked"
    end

    puts "Done".green
  end
end

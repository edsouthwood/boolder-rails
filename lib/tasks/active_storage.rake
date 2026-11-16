namespace :active_storage do
  desc "Make each published topo's photo and thumbnail ahead of time (after changing their sizes or format)"
  task process_topo_variants: :environment do
    Topo.published.find_each do |topo|
      puts "Processing topo ##{topo.id}"
      topo.display_photo.processed
      topo.photo.variant(:thumb).processed
    rescue => e
      puts "  failed: #{e.class}: #{e.message}"
    end

    puts "Done".green
  end
end

namespace :areas do
  desc "Publish an area (make it visible on the public site and in /mapping). Usage: rails areas:publish SLUG=HolwellTor"
  task publish: :environment do
    set_published(true)
  end

  desc "Unpublish an area (hide it from the public site). Usage: rails areas:unpublish SLUG=HolwellTor"
  task unpublish: :environment do
    set_published(false)
  end

  def set_published(value)
    slug = ENV["SLUG"].presence
    abort "Usage: rails areas:#{value ? "publish" : "unpublish"} SLUG=<slug>" if slug.blank?

    area = Area.find_by(slug: slug)
    abort "No area with slug #{slug.inspect}" unless area

    if area.published == value
      puts "Area ##{area.id} — #{area.name} is already #{value ? "published" : "unpublished"}. Nothing to do."
      return
    end

    area.update!(published: value)
    located = area.problems.with_location.count
    total   = area.problems.count
    puts "Area ##{area.id} — #{area.name} is now #{value ? "PUBLISHED" : "unpublished"}."
    puts "  #{located}/#{total} problems have a map location." if value
  end
end

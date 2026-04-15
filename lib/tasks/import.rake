namespace :import do
  desc "Import problems from photos in a folder. Usage: rails import:problems FOLDER=bearacleave"
  task problems: :environment do
    require "vips"

    folder = ENV["FOLDER"]
    abort "Usage: rails import:problems FOLDER=<folder_name_or_path>" if folder.blank?

    # Support both relative folder names (inside project root) and absolute paths
    photo_dir = Pathname.new(folder).absolute? ? Pathname.new(folder) : Rails.root.join(folder)
    abort "Folder not found: #{photo_dir}" unless photo_dir.directory?

    # Match area by slug or name, case-insensitively, using the folder's basename
    area_key = photo_dir.basename.to_s
    area = Area.where("lower(slug) = ? OR lower(name) = ?", area_key.downcase, area_key.downcase).first
    abort "No area found matching '#{area_key}'. Check the area slug or name in admin." unless area

    photos = Dir.glob(photo_dir.join("*.{JPG,jpg,jpeg,JPEG}")).sort
    abort "No JPG photos found in #{photo_dir}" if photos.empty?

    puts "Area:   #{area.name} (slug: #{area.slug})"
    puts "Folder: #{photo_dir}"
    puts "Photos: #{photos.count}\n\n"

    # Load existing problem names once for fuzzy matching
    existing_names = area.problems.where.not(name: nil).pluck(:name)

    created = 0
    merged  = 0
    skipped = 0

    photos.each do |path|
      filename = File.basename(path, ".*")

      # Split on LAST hyphen — handles names that contain hyphens
      last_dash = filename.rindex("-")
      unless last_dash
        puts "  ⚠ Skipping #{File.basename(path)} — no hyphen found (expected Name-grade.JPG)"
        next
      end

      name  = filename[0...last_dash].gsub("_", " ")
      grade = filename[(last_dash + 1)..]

      # Read GPS EXIF via vips
      img = Vips::Image.new_from_file(path)
      lat = parse_dms(img.get("exif-ifd3-GPSLatitude"), img.get("exif-ifd3-GPSLatitudeRef"))
      lon = parse_dms(img.get("exif-ifd3-GPSLongitude"), img.get("exif-ifd3-GPSLongitudeRef"))

      # Exact match — attempt merge
      existing = Problem.find_by(area: area, name: name, grade: grade)
      if existing
        actions = []

        if existing.topos.empty?
          topo = Topo.new(published: true)
          topo.photo.attach(io: File.open(path), filename: File.basename(path), content_type: "image/jpeg")
          topo.save!
          Line.create!(topo: topo, problem: existing)
          actions << "added photo"
        end

        if existing.location.nil? && lat && lon
          existing.update!(lat: lat, lon: lon)
          actions << "updated location"
        end

        if actions.any?
          puts "  ↳ #{name} (#{grade}) — merged into problem ##{existing.id}: #{actions.join(", ")}"
          merged += 1
        else
          puts "  ⚠ #{name} (#{grade}) — already complete, skipped"
          skipped += 1
        end
        next
      end

      # Fuzzy match warning (no exact match found)
      fuzzy_matches = existing_names.select { |n| levenshtein_distance(n.downcase, name.downcase).between?(1, 2) }
      if fuzzy_matches.any?
        puts "  ~ #{name} (#{grade}) — possible match with existing: #{fuzzy_matches.join(", ")}"
      end

      problem = Problem.create!(
        area:      area,
        name:      name,
        grade:     grade,
        steepness: "wall",
        lat:       lat,
        lon:       lon,
      )

      topo = Topo.new(published: true)
      topo.photo.attach(
        io:           File.open(path),
        filename:     File.basename(path),
        content_type: "image/jpeg",
      )
      topo.save!

      Line.create!(topo: topo, problem: problem)

      puts "  ✓ #{name} (#{grade})  #{lat.round(6)}, #{lon.round(6)}"
      created += 1
    rescue => e
      puts "  ✗ #{File.basename(path)} — #{e.message}"
    end

    puts "\nDone. Created: #{created} | Merged: #{merged} | Skipped: #{skipped}"
  end

  desc "Add open photo contribution requests to all problems in an area. Usage: rails import:request_photos AREA=bonehill"
  task request_photos: :environment do
    area_key = ENV["AREA"]
    abort "Usage: rails import:request_photos AREA=<area_slug_or_name>" if area_key.blank?

    area = Area.where("lower(slug) = ? OR lower(name) = ?", area_key.downcase, area_key.downcase).first
    abort "No area found matching '#{area_key}'." unless area

    # Use the centroid of located problems as fallback location for unlocated problems
    located = area.problems.where.not(location: nil)
    fallback_location = if located.any?
      located.first.location
    else
      abort "No located problems found in #{area.name} — cannot determine a fallback location for contribution requests."
    end

    factory = RGeo::Geographic.spherical_factory(srid: 4326)

    created = 0
    skipped = 0

    area.problems.each do |problem|
      if problem.contribution_requests.open.exists?
        skipped += 1
        next
      end

      loc = problem.location || fallback_location

      cr = ContributionRequest.new(
        problem: problem,
        what: "photo",
        state: "open",
        location_estimated: loc
      )

      if cr.save
        puts "  ✓ #{problem.name || "Problem ##{problem.id}"}"
        created += 1
      else
        puts "  ✗ #{problem.name || "Problem ##{problem.id}"} — #{cr.errors.full_messages.join(", ")}"
      end
    end

    puts "\nDone. Created: #{created} | Skipped (already had request): #{skipped}"
  end

  def parse_dms(dms_raw, ref_raw)
    parts = dms_raw.split(" (").first.split(" ").map do |rational|
      num, den = rational.split("/").map(&:to_f)
      num / den
    end
    decimal = parts[0] + parts[1] / 60.0 + parts[2] / 3600.0
    ref = ref_raw.split(" (").first.strip
    ref.match?(/[WS]/i) ? -decimal : decimal
  end

  def levenshtein_distance(a, b)
    return b.length if a.empty?
    return a.length if b.empty?

    matrix = Array.new(a.length + 1) { |i| Array.new(b.length + 1) { |j| i.zero? ? j : j.zero? ? i : 0 } }

    (1..a.length).each do |i|
      (1..b.length).each do |j|
        cost = a[i - 1] == b[j - 1] ? 0 : 1
        matrix[i][j] = [ matrix[i - 1][j] + 1, matrix[i][j - 1] + 1, matrix[i - 1][j - 1] + cost ].min
      end
    end

    matrix[a.length][b.length]
  end
end

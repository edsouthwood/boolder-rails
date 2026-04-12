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
    rescue => e
      puts "  ✗ #{File.basename(path)} — #{e.message}"
    end

    puts "\nDone."
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
end

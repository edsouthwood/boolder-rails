namespace :import do
  desc "Create the Holwell Tor area and import its problems from a CSV. " \
       "Usage: rails import:holwell_tor [CSV=holwell_boulder_problems.csv]"
  task holwell_tor: :environment do
    require "csv"

    csv_path = ENV["CSV"].presence || "holwell_boulder_problems.csv"
    csv_file = Pathname.new(csv_path).absolute? ? Pathname.new(csv_path) : Rails.root.join(csv_path)
    abort "CSV not found: #{csv_file}" unless csv_file.file?

    area_name = "Holwell Tor"
    area_slug = "HolwellTor"

    created_problems = 0
    skipped_existing = []
    skipped_bad_grade = []
    errors = []

    ActiveRecord::Base.transaction do
      area = Area.find_or_initialize_by(slug: area_slug)
      if area.new_record?
        area.name = area_name
        area.published = false
        area.priority = 3
        area.save!
        puts "Created area ##{area.id} — #{area.name} (slug: #{area.slug}, unpublished)"
      else
        puts "Using existing area ##{area.id} — #{area.name} (slug: #{area.slug})"
      end

      rows = CSV.parse(csv_file.read.force_encoding("UTF-8"), headers: true, skip_blanks: true)

      rows.each.with_index(2) do |row, line_number|
        name  = row["name"].presence
        grade = row["grade"]&.strip&.downcase.presence
        steepness = row["steepness"].presence || "other"

        if grade.blank? || !Problem::GRADE_VALUES.include?(grade)
          skipped_bad_grade << "Row #{line_number} (#{name || "unnamed"}): grade #{grade.inspect} not valid"
          next
        end

        if name.present? && Problem.exists?(area: area, name: name, grade: grade)
          skipped_existing << "Row #{line_number} — #{name} (#{grade})"
          next
        end

        problem = Problem.new(area: area, name: name, grade: grade, steepness: steepness)

        if problem.save
          created_problems += 1
        else
          errors << "Row #{line_number} (#{name || "unnamed"}): #{problem.errors.full_messages.join(", ")}"
        end
      end

      if errors.any?
        puts "\nErrors — rolling back, nothing was saved:"
        errors.each { |e| puts "  #{e}" }
        raise ActiveRecord::Rollback
      end
    end

    puts "\nCreated #{created_problems} problems."
    if skipped_existing.any?
      puts "Skipped (already exist): #{skipped_existing.count}"
      skipped_existing.each { |s| puts "  #{s}" }
    end
    if skipped_bad_grade.any?
      puts "Skipped (invalid grade): #{skipped_bad_grade.count}"
      skipped_bad_grade.each { |s| puts "  #{s}" }
    end
    puts "\nDone. The area is unpublished and its problems have no map location yet — " \
         "place them in the admin map editor, then publish the area."
  end
end

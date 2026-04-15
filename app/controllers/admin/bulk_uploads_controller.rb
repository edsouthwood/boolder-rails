require "csv"

class Admin::BulkUploadsController < Admin::BaseController
  before_action :require_super_admin

  def new
    @areas = Area.order(:name)
  end

  def create
    area = Area.find(params[:area_id])
    csv_file = params[:csv_file]
    images = Array(params[:images]).select { |f| f.respond_to?(:original_filename) }.index_by { |f| f.original_filename }

    errors = []
    skipped_conflicts = []
    skipped_no_grade = []
    fuzzy_warnings = []
    created_problems = 0
    created_topos = 0

    # Load existing problem names once for fuzzy matching
    existing_names = area.problems.where.not(name: nil).pluck(:name)

    ActiveRecord::Base.transaction do
      rows = CSV.parse(csv_file.read.force_encoding("UTF-8"), headers: true, skip_blanks: true)

      rows.each.with_index(2) do |row, line_number|
        name  = row["name"].presence
        grade = row["grade"]&.strip&.downcase&.presence

        if grade.blank? || !Problem::GRADE_VALUES.include?(grade)
          skipped_no_grade << "Row #{line_number} (#{name || "unnamed"}): skipped (grade '#{grade.presence || "blank"}' not valid for bouldering)"
          next
        end

        if name.present?
          # Exact conflict check
          existing = Problem.find_by(area: area, name: name, grade: grade)
          if existing
            skipped_conflicts << "Row #{line_number} — #{name} (#{grade || "no grade"}): already exists (problem ##{existing.id})"
            next
          end

          # Fuzzy match check
          fuzzy_matches = existing_names.select { |n| levenshtein(n.downcase, name.downcase).between?(1, 2) }
          if fuzzy_matches.any?
            fuzzy_warnings << "Row #{line_number} — #{name}: possible match with existing: #{fuzzy_matches.join(", ")}"
          end
        end

        problem = Problem.new(
          area: area,
          name: name,
          grade: grade,
          steepness: row["steepness"].presence || "other",
          sit_start: row["sit_start"]&.strip == "true",
          ukc_url: row["ukc_url"].presence,
          description: row["description"].presence,
        )

        if row["lat"].present? && row["lon"].present?
          problem.lat = row["lat"].strip
          problem.lon = row["lon"].strip
        end

        unless problem.valid?
          errors << "Row #{line_number} (#{name || "unnamed"}): #{problem.errors.full_messages.join(", ")}"
          next
        end

        problem.save!
        created_problems += 1

        image_filename = row["image_filename"]&.strip
        next if image_filename.blank?

        uploaded_file = images[image_filename]
        unless uploaded_file
          errors << "Row #{line_number}: image '#{image_filename}' not found in uploaded files"
          next
        end

        topo = Topo.new
        topo.photo.attach(
          io: uploaded_file.open,
          filename: image_filename,
          content_type: uploaded_file.content_type,
        )

        unless topo.save
          errors << "Row #{line_number}: could not save topo — #{topo.errors.full_messages.join(", ")}"
          next
        end

        created_topos += 1
      end

      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      flash.now[:error] = errors.join(" | ")
      flash.now[:conflict] = skipped_conflicts.join(" | ") if skipped_conflicts.any?
      flash.now[:skipped_no_grade] = skipped_no_grade.join(" | ") if skipped_no_grade.any?
      flash.now[:fuzzy] = fuzzy_warnings.join(" | ") if fuzzy_warnings.any?
      @areas = Area.order(:name)
      render :new, status: :unprocessable_entity
    else
      flash[:notice] = "Created #{created_problems} problems and #{created_topos} topos."
      flash[:conflict] = skipped_conflicts.join(" | ") if skipped_conflicts.any?
      flash[:skipped_no_grade] = skipped_no_grade.join(" | ") if skipped_no_grade.any?
      flash[:fuzzy] = fuzzy_warnings.join(" | ") if fuzzy_warnings.any?
      redirect_to new_admin_bulk_upload_path
    end
  end

  private

  def levenshtein(a, b)
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

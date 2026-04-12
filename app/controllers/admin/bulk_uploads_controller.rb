require "csv"

class Admin::BulkUploadsController < Admin::BaseController
  before_action :require_super_admin

  def new
    @areas = Area.order(:name)
  end

  def create
    area = Area.find(params[:area_id])
    csv_file = params[:csv_file]
    images = Array(params[:images]).index_by { |f| f.original_filename }

    errors = []
    created_problems = 0
    created_topos = 0

    ActiveRecord::Base.transaction do
      rows = CSV.parse(csv_file.read, headers: true, skip_blanks: true)

      rows.each.with_index(2) do |row, line_number|
        problem = Problem.new(
          area: area,
          name: row["name"].presence,
          grade: row["grade"].presence,
          steepness: row["steepness"].presence || "other",
          sit_start: row["sit_start"]&.strip == "true",
          ukc_url: row["ukc_url"].presence,
        )

        if row["lat"].present? && row["lon"].present?
          problem.lat = row["lat"].strip
          problem.lon = row["lon"].strip
        end

        unless problem.valid?
          errors << "Row #{line_number} (#{row["name"].presence || "unnamed"}): #{problem.errors.full_messages.join(", ")}"
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

      if errors.any?
        raise ActiveRecord::Rollback
      end
    end

    if errors.any?
      flash.now[:error] = errors.join(" | ")
      @areas = Area.order(:name)
      render :new, status: :unprocessable_entity
    else
      flash[:notice] = "Created #{created_problems} problems and #{created_topos} topos."
      redirect_to admin_root_path
    end
  end
end

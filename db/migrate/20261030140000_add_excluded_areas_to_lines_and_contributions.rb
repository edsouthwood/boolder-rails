class AddExcludedAreasToLinesAndContributions < ActiveRecord::Migration[8.1]
  def change
    add_column :lines, :excluded_areas, :json
    add_column :contributions, :excluded_areas, :json
  end
end

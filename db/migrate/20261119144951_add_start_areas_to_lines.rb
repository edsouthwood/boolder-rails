class AddStartAreasToLines < ActiveRecord::Migration[8.1]
  def change
    add_column :lines, :start_areas, :json
  end
end

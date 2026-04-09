class MakeAreaForeignKeysOptional < ActiveRecord::Migration[8.0]
  def change
    change_column_null :areas, :bleau_area_id, true
    change_column_null :areas, :cluster_id, true
  end
end

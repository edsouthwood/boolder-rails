# Lets a contribution say which crag it's from: an existing area (area_id, set when the
# contributor starts from that area's list) or free text for a crag not on the site yet.
class AddAreaToContributions < ActiveRecord::Migration[8.1]
  def change
    add_reference :contributions, :area, foreign_key: { on_delete: :nullify }, index: true
    add_column :contributions, :area_name, :string
  end
end

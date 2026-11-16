# An approximate position for a boulder, from a map-points (KML) import. It's a guide for
# drawing the outline; once drawn, the outline is what counts.
class AddLocationToBoulders < ActiveRecord::Migration[8.1]
  def change
    add_column :boulders, :location, :st_point, geographic: true, srid: 4326
  end
end

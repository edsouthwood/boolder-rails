class AddUkcUrlAndLineCoordinatesToContributions < ActiveRecord::Migration[8.0]
  def change
    add_column :contributions, :ukc_url, :string
    add_column :contributions, :line_coordinates, :json
  end
end

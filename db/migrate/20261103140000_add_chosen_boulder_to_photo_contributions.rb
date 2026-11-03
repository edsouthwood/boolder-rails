class AddChosenBoulderToPhotoContributions < ActiveRecord::Migration[8.1]
  def change
    # Whether the visitor picked the boulder from the list (else it came from GPS)
    add_column :photo_contributions, :boulder_chosen, :boolean, null: false, default: false
    # The boulder the photo's GPS points at, kept so a disagreement with the chosen one shows
    add_reference :photo_contributions, :gps_boulder, foreign_key: { to_table: :boulders, on_delete: :nullify }
  end
end

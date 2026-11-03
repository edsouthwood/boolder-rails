class CreatePhotoContributions < ActiveRecord::Migration[8.1]
  def change
    create_table :photo_contributions do |t|
      t.references :area, null: false, foreign_key: true
      t.references :boulder, foreign_key: { on_delete: :nullify }
      t.references :topo, foreign_key: { on_delete: :nullify }
      t.geography :location, limit: { srid: 4326, type: "st_point", geographic: true }
      t.string :location_source
      t.float :heading
      t.string :contributor_name
      t.string :contributor_email
      t.text :comment
      t.string :state, null: false, default: "pending"
      t.string :batch
      t.string :reviewed_by
      t.datetime :reviewed_at
      t.text :moderator_note
      t.timestamps
    end
    add_index :photo_contributions, :state
    add_index :photo_contributions, :batch
  end
end

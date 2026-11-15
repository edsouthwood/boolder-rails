class CreateCragSuggestions < ActiveRecord::Migration[8.1]
  def change
    create_table :crag_suggestions do |t|
      t.string :name, null: false
      t.geography :location, limit: { srid: 4326, type: "st_point", geographic: true }, null: false
      t.text :access_notes
      t.string :contributor_name
      t.string :contributor_email
      t.string :state, null: false, default: "pending"
      t.string :reviewed_by
      t.datetime :reviewed_at
      t.text :moderator_note
      t.references :area, foreign_key: { on_delete: :nullify }
      t.timestamps
    end
    add_index :crag_suggestions, :state

    add_reference :photo_contributions, :crag_suggestion, foreign_key: true
    change_column_null :photo_contributions, :area_id, true
    add_reference :contributions, :crag_suggestion, foreign_key: true
  end
end

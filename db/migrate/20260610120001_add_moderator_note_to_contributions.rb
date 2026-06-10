class AddModeratorNoteToContributions < ActiveRecord::Migration[8.0]
  def change
    add_column :contributions, :moderator_note, :text
  end
end

class AddHiddenToBoulders < ActiveRecord::Migration[8.1]
  # Boulders an admin has set aside for now (e.g. out of scope): the outline and every
  # problem on it are left off the public site until the boulder is shown again. Each
  # problem's own `hidden` flag is untouched, so showing the boulder restores things exactly.
  def change
    add_column :boulders, :hidden, :boolean, default: false, null: false
    add_index :boulders, :hidden, where: "hidden"
  end
end

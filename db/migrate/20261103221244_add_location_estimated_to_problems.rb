class AddLocationEstimatedToProblems < ActiveRecord::Migration[8.1]
  # True while a problem's location was guessed from a photo (its GPS, its boulder, or a
  # neighbouring problem on it) and nobody has placed it by hand yet
  def change
    add_column :problems, :location_estimated, :boolean, default: false, null: false
  end
end

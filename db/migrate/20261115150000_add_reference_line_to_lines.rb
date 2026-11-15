class AddReferenceLineToLines < ActiveRecord::Migration[8.1]
  # A better photo replacing a topo gets each problem as an undrawn line pointing at its line
  # on the old photo (reference_line), so the workbench can show the old drawing while it's
  # redrawn. Points can't be copied across: they're fractions of the other image.
  def change
    add_reference :lines, :reference_line, foreign_key: { to_table: :lines, on_delete: :nullify }
  end
end

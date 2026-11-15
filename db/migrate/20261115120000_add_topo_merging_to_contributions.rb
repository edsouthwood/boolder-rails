class AddTopoMergingToContributions < ActiveRecord::Migration[8.1]
  # Contributors often send one photo per line of the same face. An admin can instead put a
  # contribution's problem on a photo the site already has (merge_topo). The contributor's
  # line was drawn on their own photo, so it can't be copied across: the problem gets an
  # undrawn line on the kept photo, and that line points back at the contribution
  # (reference_contribution) so the workbench can show what was drawn while it's redrawn.
  def change
    add_reference :contributions, :merge_topo, foreign_key: { to_table: :topos, on_delete: :nullify }
    add_reference :lines, :reference_contribution, foreign_key: { to_table: :contributions, on_delete: :nullify }
  end
end

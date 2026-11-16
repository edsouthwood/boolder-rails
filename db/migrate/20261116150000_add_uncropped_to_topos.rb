class AddUncroppedToTopos < ActiveRecord::Migration[8.1]
  # Topos uploaded until now were stored cropped to 4:3 and their lines fit the crop, so they
  # stay cropped; every topo made from here on keeps the photo's own shape.
  def change
    add_column :topos, :uncropped, :boolean, default: false, null: false
    change_column_default :topos, :uncropped, from: false, to: true
  end
end

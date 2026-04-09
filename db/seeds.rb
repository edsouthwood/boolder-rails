# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rails db:seed command (or created alongside the database with db:setup).

Area.find_or_create_by!(name: "Dartmoor") do |a|
  a.description_en = "Granite bouldering on Dartmoor, Devon."
  a.published = false
  a.slug = "dartmoor"
end

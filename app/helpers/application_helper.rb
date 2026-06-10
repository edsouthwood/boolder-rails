module ApplicationHelper
  # Top-nav link classes, highlighting the section the visitor is currently in.
  def nav_link_classes(active:)
    base = "flex items-center px-1 pt-1 font-medium border-b-2 "
    if active
      base + "border-emerald-500 text-gray-900"
    else
      base + "border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-900"
    end
  end
end

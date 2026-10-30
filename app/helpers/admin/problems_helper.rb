module Admin::ProblemsHelper
  # Column header that sorts the area problems list, toggling asc/desc and keeping the other filters
  def problems_sort_link(label, column)
    active = params[:sort] == column
    dir = active && params[:dir] != "desc" ? "desc" : "asc"
    arrow = active ? (params[:dir] == "desc" ? " ▼" : " ▲") : ""
    query = params.permit(:circuit_id, :missing).to_h.symbolize_keys.merge(sort: column, dir: dir)

    link_to "#{label}#{arrow}", admin_area_problems_path(query), class: active ? "text-gray-900" : "hover:text-gray-700"
  end
end

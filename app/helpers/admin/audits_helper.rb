module Admin::AuditsHelper
  # "Type #id", linked to the record's admin page when it has one. Not every
  # audited model does (photo contributions, boulders, accounts...), and
  # [:admin, record] raises for those, which used to take the whole log down.
  def audit_record_link(type, id, record)
    label = "#{type} ##{id}"
    path = record && admin_show_path_for(record)
    path ? link_to(label, path) : label
  end

  private

  def admin_show_path_for(record)
    path = polymorphic_path([ :admin, record ])
    Rails.application.routes.recognize_path(path, method: :get)
    path
  rescue NoMethodError, ActionController::RoutingError
    nil
  end
end

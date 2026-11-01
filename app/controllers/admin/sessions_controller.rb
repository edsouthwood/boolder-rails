class Admin::SessionsController < Admin::BaseController
  # Sign out of admin. The next admin page asks for the password again.
  def destroy
    end_admin_session
    session[:admin_signed_out] = true
    redirect_to root_localized_path, notice: "Signed out of admin"
  end
end

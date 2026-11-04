# Admin → My account: see your role and areas, change your own password
class Admin::ProfilesController < Admin::BaseController
  def show; end

  def update
    unless current_account
      return redirect_to admin_profile_path, flash: { error: "Your login comes from the server's credentials file, so its password is changed there" }
    end
    unless current_account.authenticate(params[:current_password].to_s)
      flash.now[:error] = "Your current password wasn't right"
      return render :show, status: :unprocessable_entity
    end

    account = current_account
    account.assign_attributes(password: params[:password].to_s, password_confirmation: params[:password_confirmation].to_s)
    account.audit_comment = "changed own password"
    if params[:password].blank?
      account.errors.add(:password, "can't be blank")
    elsif account.save
      # Other browsers are signed out; this one stays signed in
      session[:admin_session_version] = account.session_version
      return redirect_to admin_profile_path, notice: "Password changed. You've been signed out on any other devices"
    end
    @errors = account.errors.full_messages
    account.restore_attributes
    render :show, status: :unprocessable_entity
  end
end

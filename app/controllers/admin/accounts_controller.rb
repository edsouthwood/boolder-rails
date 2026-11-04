# Admin → Accounts (super admins): add admins, change their role and areas, reset their
# password, disable or delete them. Every change needs your own password again.
class Admin::AccountsController < Admin::BaseController
  before_action :require_super_admin
  before_action :set_account, only: [ :edit, :update, :destroy ]
  before_action :confirm_own_password, only: [ :create, :update, :destroy ]

  def index
    @accounts = AdminAccount.order(Arel.sql("disabled_at IS NOT NULL"), :username)
    @credentials_in_use = !database_accounts?
  end

  def new
    @account = AdminAccount.new(role: "area_admin")
  end

  def create
    @account = AdminAccount.new(account_params.except(:password))
    generated = account_params[:password].blank?
    password = generated ? AdminAccount.generate_password : account_params[:password]
    @account.password = password
    @account.audit_comment = "account created"

    if @account.save
      flash[:generated_password] = { "username" => @account.username, "password" => password } if generated
      redirect_to admin_accounts_path, notice: "Added #{@account.username}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    attrs = account_params.except(:username)
    new_password = attrs.delete(:password).presence
    generate = params[:generate_password] == "1"

    if @account == current_account && (attrs[:role] && attrs[:role] != @account.role || ActiveModel::Type::Boolean.new.cast(attrs[:disabled]))
      flash.now[:error] = "You can't change your own role or disable yourself: ask another super admin"
      return render :edit, status: :unprocessable_entity
    end

    @account.assign_attributes(attrs)
    password = new_password || (AdminAccount.generate_password if generate)
    @account.password = password if password
    @account.audit_comment = "password reset" if password

    if @account.save
      session[:admin_session_version] = @account.session_version if @account == current_account
      flash[:generated_password] = { "username" => @account.username, "password" => password } if generate && !new_password
      redirect_to admin_accounts_path, notice: "Updated #{@account.username}#{" and signed them out everywhere" if password}"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @account.destroy
      redirect_to admin_accounts_path, notice: "Deleted #{@account.username}"
    else
      redirect_to edit_admin_account_path(@account), flash: { error: @account.errors.full_messages.to_sentence }
    end
  end

  private

  def set_account
    @account = AdminAccount.find(params[:id])
  end

  # Role is checked against the allowed list, not mass-assigned (the page is super-admin only anyway)
  def account_params
    permitted = params.require(:admin_account).permit(:username, :password, :disabled, area_slugs: [])
    role = params.dig(:admin_account, :role).to_s.presence_in(AdminAccount::ROLES)
    role ? permitted.merge(role: role) : permitted
  end

  def confirm_own_password
    return if own_password_correct?(params[:current_password])

    message = "Your own password wasn't right, so nothing was changed"
    return redirect_to(edit_admin_account_path(@account), flash: { error: message }) if action_name == "destroy"

    @account ||= AdminAccount.new(account_params.except(:password))
    @account.assign_attributes(account_params.except(:username, :password)) if @account.persisted? && action_name == "update"
    flash.now[:error] = message
    render(action_name == "create" ? :new : :edit, status: :unprocessable_entity)
  end
end

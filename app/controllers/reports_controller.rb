class ReportsController < ApplicationController
  invisible_captcha only: [ :create ], on_spam: :handle_spam

  def new
    @contribution = Contribution.new(
      # TODO: make DRY
      contributor_name: session[:contribution_name],
      contributor_email: session[:contribution_email],
    )
  end

  def create
    @contribution = Contribution.new(contribution_params)

    # TODO: make DRY
    session[:contribution_name] = @contribution.contributor_name
    session[:contribution_email] = @contribution.contributor_email

    if @contribution.save
      flash[:notice] = t("views.reports.new.flash_success")

      ContributeMailer.with(contribution: @contribution).new_contribution_email.deliver_later

      redirect_to contribute_path
    else
      # flash[:error] = "Error"
      render "new", status: :unprocessable_entity
    end
  end

  private

  # invisible_captcha honeypot tripped — silently drop and send the bot home.
  def handle_spam
    redirect_to contribute_path
  end

  def contribution_params
    params.require(:contribution).permit(
      :comment, :contributor_name, :contributor_email
    )
  end
end

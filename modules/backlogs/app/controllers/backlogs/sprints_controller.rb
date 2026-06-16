# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

module Backlogs
  class SprintsController < ::RbApplicationController
    include OpTurbo::ComponentStream

    NEW_SPRINT_ACTIONS = %i[new_dialog
                            edit_dialog
                            create
                            refresh_form].freeze
    SPRINT_STATE_ACTIONS = %i[start finish].freeze

    skip_before_action :load_sprint_and_project, only: NEW_SPRINT_ACTIONS
    skip_before_action :authorize, only: SPRINT_STATE_ACTIONS

    before_action :load_project, only: NEW_SPRINT_ACTIONS
    before_action :authorize_start!, only: :start
    before_action :authorize_finish!, only: :finish

    def new_dialog
      call = ::Sprints::SetAttributesService.new(
        user: current_user,
        model: Agile::Sprint.new,
        contract_class: ::EmptyContract
      ).call(attributes: converted_agile_sprint_params)

      respond_with_dialog Backlogs::NewSprintDialogComponent.new(sprint: call.result)
    end

    def edit_dialog
      @sprint = Agile::Sprint.for_project(@project).visible.find(params[:sprint_id])

      respond_with_dialog Backlogs::NewSprintDialogComponent.new(sprint: @sprint, state: :edit)
    end

    def refresh_form
      id = edit_agile_sprint_params.dig(:sprint, :id)
      sprint = id.present? ? Agile::Sprint.for_project(@project).visible.find(id) : Agile::Sprint.new

      call = ::Sprints::SetAttributesService.new(
        user: current_user,
        model: sprint,
        contract_class: ::EmptyContract
      ).call(attributes: converted_agile_sprint_params)

      update_via_turbo_stream(component: Backlogs::NewSprintFormComponent.new(sprint: call.result))

      respond_with_turbo_streams
    end

    def create # rubocop:disable Metrics/AbcSize
      call = ::Sprints::CreateService
               .new(user: current_user)
               .call(attributes: converted_agile_sprint_params)

      if call.success?
        flash[:notice] = I18n.t(:notice_successful_create)
        render turbo_stream: turbo_stream.redirect_to(project_backlogs_backlog_path(@project))
      else
        update_new_sprint_form_component_via_turbo_stream(sprint: call.result, base_errors: call.errors[:base])
        respond_with_turbo_streams
      end
    end

    def update
      call = ::Sprints::UpdateService
               .new(user: current_user, model: @sprint)
               .call(attributes: agile_sprint_params[:sprint])

      if call.success?
        render_success_flash_message_via_turbo_stream(message: I18n.t(:notice_successful_update))
        update_sprint_header_component_via_turbo_stream(sprint: call.result)
      else
        update_new_sprint_form_component_via_turbo_stream(sprint: call.result, base_errors: call.errors[:base])
      end

      respond_with_turbo_streams
    end

    def start
      result = start_sprint

      if result.success?
        @sprint = result.result
        flash[:notice] = I18n.t(:notice_successful_start)
        render turbo_stream: turbo_stream.redirect_to(
          kanban_project_work_package_boards_path(@project)
        )
      else
        respond_with_start_finish_failure(message: start_finish_failure_message(:start, result.message))
      end
    end

    def finish
      result = finish_sprint

      if result.success?
        flash[:notice] = I18n.t(:notice_successful_finish)
        render turbo_stream: turbo_stream.redirect_to(project_backlogs_backlog_path(@project))
      elsif result.includes_error?(:base, :unfinished_work_packages)
        show_finish_sprint_dialog
      else
        respond_with_start_finish_failure(message: start_finish_failure_message(:finish, result.message))
      end
    end

    private

    def update_sprint_header_component_via_turbo_stream(sprint:)
      update_via_turbo_stream(
        component: Backlogs::SprintHeaderComponent.new(sprint:, project: @project),
        method: :morph
      )
    end

    def update_new_sprint_form_component_via_turbo_stream(sprint:, base_errors: nil)
      update_via_turbo_stream(
        component: Backlogs::NewSprintFormComponent.new(
          sprint:,
          base_errors:
        ),
        status: :bad_request
      )
    end

    def show_finish_sprint_dialog
      respond_with_dialog(
        Backlogs::FinishSprintDialogComponent.new(
          sprint: @sprint,
          project: @project,
          available_sprints: Agile::Sprint.native_to_sprint_source(@project).in_planning.where.not(id: @sprint.id).order_by_date
        )
      )
    end

    def load_sprint_and_project
      load_project

      sprint_id = params[:sprint_id]
      @sprint = Agile::Sprint.for_project(@project).visible.find(sprint_id) if sprint_id
    end

    def agile_sprint_params
      params.permit(sprint: %i[name start_date finish_date])
    end

    def edit_agile_sprint_params
      params.permit(sprint: %i[id name start_date finish_date])
    end

    def converted_agile_sprint_params
      converted_sprint_params = agile_sprint_params[:sprint].to_h
      converted_sprint_params[:project] = @project

      converted_sprint_params
    end

    def start_sprint
      ::Sprints::StartService
        .new(user: current_user, model: @sprint)
        .call(send_notifications: false)
    end

    def finish_sprint
      ::Sprints::FinishService
        .new(user: current_user, model: @sprint)
        .call(
          unfinished_action: params[:unfinished_action],
          move_to_sprint_id: params[:move_to_sprint_id],
          send_notifications: false
        )
    end

    def respond_with_start_finish_failure(message:)
      render_error_flash_message_via_turbo_stream(message:)

      respond_with_turbo_streams(status: :unprocessable_entity) do |format|
        fallback_responses_for(format, alert: message)
      end
    end

    def fallback_responses_for(format, **)
      format.html { redirect_back_or_to(project_backlogs_backlog_path(@project), **) }
    end

    def start_finish_failure_message(action, reason)
      if reason.present?
        I18n.t(:"notice_unsuccessful_#{action}_with_reason", reason:)
      else
        I18n.t(:"notice_unsuccessful_#{action}")
      end
    end

    def authorize_start!
      deny_access unless current_user.allowed_in_project?(:view_sprints, @project) &&
        ::Sprints::StartContract.can_start?(user: current_user, sprint: @sprint, project: @project)
    end

    def authorize_finish!
      deny_access unless current_user.allowed_in_project?(:view_sprints, @project) &&
        ::Sprints::StartContract.can_start_or_complete?(user: current_user, sprint: @sprint)
    end
  end
end

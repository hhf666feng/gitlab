module API
  class Runners < Grape::API
    include PaginationParams

    before { authenticate! }

    resource :runners do
      desc 'Get runners available for user' do
        success Entities::Runner
      end
      params do
        optional :scope, type: String, values: %w[active paused online],
                         desc: 'The scope of specific runners to show'
        use :pagination
      end
      get do
        runners = filter_runners(current_user.ci_authorized_runners, params[:scope], without: ['specific', 'shared'])
        present paginate(runners), with: Entities::Runner
      end

      desc 'Get all runners - shared and specific' do
        success Entities::Runner
      end
      params do
        optional :scope, type: String, values: %w[active paused online specific shared],
                         desc: 'The scope of specific runners to show'
        use :pagination
      end
      get 'all' do
        authenticated_as_admin!
        runners = filter_runners(Ci::Runner.all, params[:scope])
        present paginate(runners), with: Entities::Runner
      end

      desc "Get runner's details" do
        success Entities::RunnerDetails
      end
      params do
        requires :id, type: Integer, desc: 'The ID of the runner'
      end
      get ':id' do
        runner = get_runner(params[:id])
        authenticate_show_runner!(runner)

        present runner, with: Entities::RunnerDetails, current_user: current_user
      end

      desc "Update runner's details" do
        success Entities::RunnerDetails
      end
      params do
        requires :id, type: Integer, desc: 'The ID of the runner'
        optional :description, type: String, desc: 'The description of the runner'
        optional :active, type: Boolean, desc: 'The state of a runner'
        optional :tag_list, type: Array[String], desc: 'The list of tags for a runner'
        optional :run_untagged, type: Boolean, desc: 'Flag indicating the runner can execute untagged jobs'
        optional :locked, type: Boolean, desc: 'Flag indicating the runner is locked'
        at_least_one_of :description, :active, :tag_list, :run_untagged, :locked
      end
      put ':id' do
        runner = get_runner(params.delete(:id))
        authenticate_update_runner!(runner)

        if runner.update(declared_params(include_missing: false))
          present runner, with: Entities::RunnerDetails, current_user: current_user
        else
          render_validation_error!(runner)
        end
      end

      desc 'Remove a runner' do
        success Entities::Runner
      end
      params do
        requires :id, type: Integer, desc: 'The ID of the runner'
      end
      delete ':id' do
        runner = get_runner(params[:id])
        authenticate_delete_runner!(runner)
        runner.destroy!

        present runner, with: Entities::Runner
      end
    end

    params do
      requires :id, type: String, desc: 'The ID of a project'
    end
    resource :projects do
      before { authorize_admin_project }

      desc 'Get runners available for project' do
        success Entities::Runner
      end
      params do
        optional :scope, type: String, values: %w[active paused online specific shared],
                         desc: 'The scope of specific runners to show'
        use :pagination
      end
      get ':id/runners' do
        runners = filter_runners(Ci::Runner.owned_or_shared(user_project.id), params[:scope])
        present paginate(runners), with: Entities::Runner
      end

      desc 'Enable a runner for a project' do
        success Entities::Runner
      end
      params do
        requires :runner_id, type: Integer, desc: 'The ID of the runner'
      end
      post ':id/runners' do
        runner = get_runner(params[:runner_id])
        authenticate_enable_runner!(runner)

        runner_project = runner.assign_to(user_project)

        if runner_project.persisted?
          present runner, with: Entities::Runner
        else
          conflict!("Runner was already enabled for this project")
        end
      end

      desc "Disable project's runner" do
        success Entities::Runner
      end
      params do
        requires :runner_id, type: Integer, desc: 'The ID of the runner'
      end
      delete ':id/runners/:runner_id' do
        runner_project = user_project.runner_projects.find_by(runner_id: params[:runner_id])
        not_found!('Runner') unless runner_project

        runner = runner_project.runner
        forbidden!("Only one project associated with the runner. Please remove the runner instead") if runner.projects.count == 1

        runner_project.destroy

        present runner, with: Entities::Runner
      end
    end

    helpers do
      def filter_runners(runners, scope, options = {})
        return runners unless scope.present?

        available_scopes = ::Ci::Runner::AVAILABLE_SCOPES
        if options[:without]
          available_scopes = available_scopes - options[:without]
        end

        if (available_scopes & [scope]).empty?
          render_api_error!('Scope contains invalid value', 400)
        end

        runners.send(scope)
      end

      def get_runner(id)
        runner = Ci::Runner.find(id)
        not_found!('Runner') unless runner
        runner
      end

      def authenticate_show_runner!(runner)
        return if runner.is_shared || current_user.is_admin?
        forbidden!("No access granted") unless user_can_access_runner?(runner)
      end

      def authenticate_update_runner!(runner)
        return if current_user.is_admin?
        forbidden!("Runner is shared") if runner.is_shared?
        forbidden!("No access granted") unless user_can_access_runner?(runner)
      end

      def authenticate_delete_runner!(runner)
        return if current_user.is_admin?
        forbidden!("Runner is shared") if runner.is_shared?
        forbidden!("Runner associated with more than one project") if runner.projects.count > 1
        forbidden!("No access granted") unless user_can_access_runner?(runner)
      end

      def authenticate_enable_runner!(runner)
        forbidden!("Runner is shared") if runner.is_shared?
        forbidden!("Runner is locked") if runner.locked?
        return if current_user.is_admin?
        forbidden!("No access granted") unless user_can_access_runner?(runner)
      end

      def user_can_access_runner?(runner)
        current_user.ci_authorized_runners.exists?(runner.id)
      end
    end
  end
end

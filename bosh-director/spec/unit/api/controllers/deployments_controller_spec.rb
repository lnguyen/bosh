require 'spec_helper'
require 'rack/test'

module Bosh::Director
  module Api
    describe Controllers::DeploymentsController do
      include Rack::Test::Methods

      subject(:app) { described_class.new(config) }

      let(:config) do
        config = Config.load_hash(SpecHelper.spec_get_director_config)
        identity_provider = Support::TestIdentityProvider.new(config.get_uuid_provider)
        allow(config).to receive(:identity_provider).and_return(identity_provider)
        config
      end

      def manifest_with_errand(deployment_name='errand')
        manifest_hash = Bosh::Spec::Deployments.manifest_with_errand
        manifest_hash['name'] = deployment_name
        manifest_hash['jobs'] << {
          'name' => 'another-errand',
          'template' => 'errand1',
          'lifecycle' => 'errand',
          'resource_pool' => 'a',
          'instances' => 1,
          'networks' => [{'name' => 'a'}]
        }
        Psych.dump(manifest_hash)
      end

      let(:cloud_config) { Models::CloudConfig.make }
      before do
        App.new(config)
        basic_authorize 'admin', 'admin'
      end

      describe 'the date header' do
        it 'is present' do
          basic_authorize 'reader', 'reader'
          get '/'
          expect(last_response.headers['Date']).to be
        end
      end

      describe 'API calls' do
        describe 'creating a deployment' do
          it 'expects compressed deployment file' do
            post '/', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'only consumes text/yaml' do
            post '/', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/plain' }
            expect(last_response.status).to eq(404)
          end

          it 'gives a nice error when request body is not a valid yml' do
            post '/', "}}}i'm not really yaml, hah!", {'CONTENT_TYPE' => 'text/yaml'}

            expect(last_response.status).to eq(400)
            expect(JSON.parse(last_response.body)['code']).to eq(440001)
            expect(JSON.parse(last_response.body)['description']).to include('Incorrect YAML structure of the uploaded manifest: ')
          end

          it 'gives a nice error when request body is empty' do
            post '/', '', {'CONTENT_TYPE' => 'text/yaml'}

            expect(last_response.status).to eq(400)
            expect(JSON.parse(last_response.body)).to eq(
                'code' => 440001,
                'description' => 'Manifest should not be empty',
            )
          end
        end

        describe 'updating a deployment' do
          let!(:deployment) { Models::Deployment.create(:name => 'my-test-deployment', :manifest => Psych.dump({'foo' => 'bar'})) }

          context 'without the "skip_drain" param' do
            it 'does not skip draining' do
              allow_any_instance_of(DeploymentManager)
                .to receive(:create_deployment)
                .with(anything(), anything(), anything(), anything(), anything(), hash_excluding('skip_drain'))
                .and_return(OpenStruct.new(:id => 1))
              post '/', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
              expect(last_response).to be_redirect
            end
          end

          context 'with the "skip_drain" param as "*"' do
            it 'skips draining' do
              allow_any_instance_of(DeploymentManager)
                .to receive(:create_deployment)
                .with(anything(), anything(), anything(), anything(), anything(), hash_including('skip_drain' => '*'))
                .and_return(OpenStruct.new(:id => 1))
              post '/?skip_drain=*', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
              expect(last_response).to be_redirect
            end
          end

          context 'with the "skip_drain" param as "job_one,job_two"' do
            it 'skips draining' do
              allow_any_instance_of(DeploymentManager)
                .to receive(:create_deployment)
                .with(anything(), anything(), anything(), anything(), anything(), hash_including('skip_drain' => 'job_one,job_two'))
                .and_return(OpenStruct.new(:id => 1))
              post '/?skip_drain=job_one,job_two', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
              expect(last_response).to be_redirect
            end
          end

          context 'updates using a manifest with deployment name' do
            it 'calls create deployment with deployment name' do
              expect_any_instance_of(DeploymentManager)
                  .to receive(:create_deployment)
                          .with(anything(), anything(), anything(), anything(), deployment, hash_excluding('skip_drain'))
                          .and_return(OpenStruct.new(:id => 1))
              post '/', spec_asset('test_manifest.yml'), { 'CONTENT_TYPE' => 'text/yaml' }
              expect(last_response).to be_redirect
            end
          end

          context 'sets `new` option' do
            it 'to false' do
              expect_any_instance_of(DeploymentManager)
                  .to receive(:create_deployment)
                          .with(anything(), anything(), anything(), anything(), deployment, hash_including('new' => false))
                          .and_return(OpenStruct.new(:id => 1))
              post '/', spec_asset('test_manifest.yml'), { 'CONTENT_TYPE' => 'text/yaml' }
            end

            it 'to true' do
              expect_any_instance_of(DeploymentManager)
                  .to receive(:create_deployment)
                          .with(anything(), anything(), anything(), anything(), anything(), hash_including('new' => true))
                          .and_return(OpenStruct.new(:id => 1))
               Models::Deployment.first.delete
              post '/', spec_asset('test_manifest.yml'), { 'CONTENT_TYPE' => 'text/yaml' }
            end
          end

        end

        describe 'deleting deployment' do
          it 'deletes the deployment' do
            deployment = Models::Deployment.create(:name => 'test_deployment', :manifest => Psych.dump({'foo' => 'bar'}))

            delete '/test_deployment'
            expect_redirect_to_queued_task(last_response)
          end
        end

        describe 'job management' do
          shared_examples 'change state' do
            it 'allows to change state' do
              deployment = Models::Deployment.create(name: 'foo', manifest: Psych.dump({'foo' => 'bar'}))
              instance = Models::Instance.create(deployment: deployment, job: 'dea', index: '2', uuid: '0B949287-CDED-4761-9002-FC4035E11B21', state: 'started')
              Models::PersistentDisk.create(instance: instance, disk_cid: 'disk_cid')
              put "#{path}", spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
              expect_redirect_to_queued_task(last_response)
            end

            it 'allows to change state with content_length of 0' do
              RSpec::Matchers.define :not_to_have_body do |unexpected|
                match { |actual| actual != unexpected }
              end
              manifest = spec_asset('test_conf.yaml')
              manifest_path = asset('test_conf.yaml')
              allow_any_instance_of(DeploymentManager).to receive(:create_deployment).
                  with(anything(), not_to_have_body(manifest_path), anything(), anything(), anything(), anything()).
                  and_return(OpenStruct.new(:id => 'no_content_length'))
              deployment = Models::Deployment.create(name: 'foo', manifest: Psych.dump({'foo' => 'bar'}))
              instance = Models::Instance.create(deployment: deployment, job: 'dea', index: '2', uuid: '0B949287-CDED-4761-9002-FC4035E11B21', state: 'started')
              Models::PersistentDisk.create(instance: instance, disk_cid: 'disk_cid')
              put "#{path}", manifest, {'CONTENT_TYPE' => 'text/yaml', 'CONTENT_LENGTH' => 0}
              match = last_response.location.match(%r{/tasks/no_content_length})
              expect(match).to_not be_nil
            end

            it 'should return 404 if the manifest cannot be found' do
              put "#{path}", spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
              expect(last_response.status).to eq(404)
            end
          end

          context 'for all jobs in deployment' do
            let (:path) { '/foo/jobs/*?state=stopped' }
            it_behaves_like 'change state'
          end
          context 'for one job in deployment' do
            let (:path) { '/foo/jobs/dea?state=stopped' }
            it_behaves_like 'change state'
          end
          context 'for job instance in deployment by index' do
            let (:path) { '/foo/jobs/dea/2?state=stopped' }
            it_behaves_like 'change state'
          end
          context 'for job instance in deployment by id' do
            let (:path) { '/foo/jobs/dea/0B949287-CDED-4761-9002-FC4035E11B21?state=stopped' }
            it_behaves_like 'change state'
          end

          let(:deployment) do
            Models::Deployment.create(name: 'foo', manifest: Psych.dump({'foo' => 'bar'}))
          end

          it 'allows putting the job instance into different resurrection_paused values' do
            instance = Models::Instance.
                create(:deployment => deployment, :job => 'dea',
                       :index => '0', :state => 'started')
            put '/foo/jobs/dea/0/resurrection', JSON.generate('resurrection_paused' => true), { 'CONTENT_TYPE' => 'application/json' }
            expect(last_response.status).to eq(200)
            expect(instance.reload.resurrection_paused).to be(true)
          end

          it 'allows putting the job instance into different ignore state' do
            instance = Models::Instance.
                create(:deployment => deployment, :job => 'dea',
                       :index => '0', :state => 'started', :uuid => '0B949287-CDED-4761-9002-FC4035E11B21')
            expect(instance.ignore).to be(false)
            put '/foo/instance_groups/dea/0B949287-CDED-4761-9002-FC4035E11B21/ignore', JSON.generate('ignore' => true), { 'CONTENT_TYPE' => 'application/json' }
            expect(last_response.status).to eq(200)
            expect(instance.reload.ignore).to be(true)

            put '/foo/instance_groups/dea/0B949287-CDED-4761-9002-FC4035E11B21/ignore', JSON.generate('ignore' => false), { 'CONTENT_TYPE' => 'application/json' }
            expect(last_response.status).to eq(200)
            expect(instance.reload.ignore).to be(false)
          end

          it 'gives a nice error when uploading non valid manifest' do
            instance = Models::Instance.
                create(:deployment => deployment, :job => 'dea',
                       :index => '0', :state => 'started')

            put "/foo/jobs/dea", "}}}i'm not really yaml, hah!", {'CONTENT_TYPE' => 'text/yaml'}

            expect(last_response.status).to eq(400)
            expect(JSON.parse(last_response.body)['code']).to eq(440001)
            expect(JSON.parse(last_response.body)['description']).to include('Incorrect YAML structure of the uploaded manifest: ')
          end

          it 'should not validate body content when content.length is zero' do
            Models::Instance.
                create(:deployment => deployment, :job => 'dea',
                       :index => '0', :state => 'started')

            put "/foo/jobs/dea/0?state=started", "}}}i'm not really yaml, hah!", {'CONTENT_TYPE' => 'text/yaml', 'CONTENT_LENGTH' => 0}

            expect(last_response.status).to eq(302)
          end

          it 'returns a "bad request" if index_or_id parameter of a PUT is neither a number nor a string with uuid format' do
            deployment
            put '/foo/jobs/dea/snoopy?state=stopped', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
            expect(last_response.status).to eq(400)
          end

          it 'can get job information' do
            instance = Models::Instance.create(deployment: deployment, job: 'nats', index: '0', uuid: 'fake_uuid', state: 'started')
            Models::PersistentDisk.create(instance: instance, disk_cid: 'disk_cid')

            get '/foo/jobs/nats/0', {}

            expect(last_response.status).to eq(200)
            expected = {
                'deployment' => 'foo',
                'job' => 'nats',
                'index' => 0,
                'id' => 'fake_uuid',
                'state' => 'started',
                'disks' => %w[disk_cid]
            }

            expect(JSON.parse(last_response.body)).to eq(expected)
          end

          it 'should return 404 if the instance cannot be found' do
            get '/foo/jobs/nats/0', {}
            expect(last_response.status).to eq(404)
          end

          context 'with a "canaries" param' do
            it 'overrides the canaries value from the manifest' do
              deployment
              expect_any_instance_of(DeploymentManager)
                .to receive(:create_deployment)
                  .with(anything(), anything(), anything(), anything(), anything(), hash_including('canaries'=>'42') )
                  .and_return(OpenStruct.new(:id => 1))

              put '/foo/jobs/dea?canaries=42', JSON.generate('value' => 'baz'), { 'CONTENT_TYPE' => 'text/yaml' }
              expect(last_response).to be_redirect
            end
          end

          context 'with a "max_in_flight" param' do
            it 'overrides the "max_in_flight" value from the manifest' do
              deployment
              expect_any_instance_of(DeploymentManager)
                .to receive(:create_deployment)
                      .with(anything(), anything(), anything(), anything(), anything(), hash_including('max_in_flight'=>'42') )
                      .and_return(OpenStruct.new(:id => 1))

              put '/foo/jobs/dea?max_in_flight=42', JSON.generate('value' => 'baz'), { 'CONTENT_TYPE' => 'text/yaml' }
              expect(last_response).to be_redirect
            end
          end

          describe 'draining' do
            let(:deployment) { Models::Deployment.create(:name => 'test_deployment', :manifest => Psych.dump({'foo' => 'bar'})) }
            let(:instance) { Models::Instance.create(deployment: deployment, job: 'job_name', index: '0', uuid: '0B949287-CDED-4761-9002-FC4035E11B21', state: 'started') }
            before do
              Models::PersistentDisk.create(instance: instance, disk_cid: 'disk_cid')
            end

            shared_examples 'skip_drain' do
              it 'drains' do
                allow_any_instance_of(DeploymentManager).to receive(:find_by_name).and_return(deployment)
                allow_any_instance_of(DeploymentManager)
                    .to receive(:create_deployment)
                            .with(anything(), anything(), anything(), anything(), anything(), hash_excluding('skip_drain'))
                            .and_return(OpenStruct.new(:id => 1))

                put "#{path}", spec_asset('test_conf.yaml'), {'CONTENT_TYPE' => 'text/yaml'}
                expect(last_response).to be_redirect

                put '/test_deployment/jobs/job_name/0B949287-CDED-4761-9002-FC4035E11B21', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
                expect(last_response).to be_redirect
              end

              it 'skips draining' do
                allow_any_instance_of(DeploymentManager).to receive(:find_by_name).and_return(deployment)
                allow_any_instance_of(DeploymentManager)
                    .to receive(:create_deployment)
                            .with(anything(), anything(), anything(), anything(), anything(), hash_including('skip_drain' => "#{drain_target}"))
                            .and_return(OpenStruct.new(:id => 1))

                put "#{path + drain_option}", spec_asset('test_conf.yaml'), {'CONTENT_TYPE' => 'text/yaml'}
                expect(last_response).to be_redirect
              end
            end

            context 'when there is a job instance' do
              let(:path) { "/test_deployment/jobs/job_name/0" }
              let(:drain_option) { "?skip_drain=true" }
              let(:drain_target) { "job_name" }
              it_behaves_like 'skip_drain'
            end

            context 'when there is a  job' do
              let(:path) { "/test_deployment/jobs/job_name?state=stop" }
              let(:drain_option) { "&skip_drain=true" }
              let(:drain_target) { "job_name" }
              it_behaves_like 'skip_drain'
            end

            context 'when  deployment' do
              let(:path) { "/test_deployment/jobs/*?state=stop" }
              let(:drain_option) { "&skip_drain=true" }
              let(:drain_target) { "*" }
              it_behaves_like 'skip_drain'
            end
          end
        end

        describe 'log management' do
          it 'allows fetching logs from a particular instance' do
            deployment = Models::Deployment.create(:name => 'foo', :manifest => Psych.dump({'foo' => 'bar'}))
            Models::Instance.create(
              :deployment => deployment,
              :job => 'nats',
              :index => '0',
              :state => 'started',
            )
            get '/foo/jobs/nats/0/logs', {}
            expect_redirect_to_queued_task(last_response)
          end

          it '404 if no instance' do
            get '/baz/jobs/nats/0/logs', {}
            expect(last_response.status).to eq(404)
          end

          it '404 if no deployment' do
            deployment = Models::Deployment.
              create(:name => 'bar', :manifest => Psych.dump({'foo' => 'bar'}))
            get '/bar/jobs/nats/0/logs', {}
            expect(last_response.status).to eq(404)
          end
        end

        describe 'listing deployments' do
          before { basic_authorize 'reader', 'reader' }

          it 'lists deployment info in deployment name order' do
            release_1 = Models::Release.create(:name => 'release-1')
            release_1_1 = Models::ReleaseVersion.create(:release => release_1, :version => 1)
            release_1_2 = Models::ReleaseVersion.create(:release => release_1, :version => 2)
            release_2 = Models::Release.create(:name => 'release-2')
            release_2_1 = Models::ReleaseVersion.create(:release => release_2, :version => 1)

            stemcell_1_1 = Models::Stemcell.create(name: 'stemcell-1', version: 1, cid: 123)
            stemcell_1_2 = Models::Stemcell.create(name: 'stemcell-1', version: 2, cid: 123)
            stemcell_2_1 = Models::Stemcell.create(name: 'stemcell-2', version: 1, cid: 124)

            old_cloud_config = Models::CloudConfig.make(manifest: {}, created_at: Time.now - 60)
            new_cloud_config = Models::CloudConfig.make(manifest: {})

            deployment_3 = Models::Deployment.create(
              name: 'deployment-3',
            )

            deployment_2 = Models::Deployment.create(
              name: 'deployment-2',
              cloud_config: new_cloud_config,
            ).tap do |deployment|
              deployment.add_stemcell(stemcell_1_1)
              deployment.add_stemcell(stemcell_1_2)
              deployment.add_release_version(release_1_1)
              deployment.add_release_version(release_2_1)
            end

            deployment_1 = Models::Deployment.create(
              name: 'deployment-1',
              cloud_config: old_cloud_config,
            ).tap do |deployment|
              deployment.add_stemcell(stemcell_1_1)
              deployment.add_stemcell(stemcell_2_1)
              deployment.add_release_version(release_1_1)
              deployment.add_release_version(release_1_2)
            end

            get '/', {}, {}
            expect(last_response.status).to eq(200)

            body = JSON.parse(last_response.body)
            expect(body).to eq([
                  {
                    'name' => 'deployment-1',
                    'releases' => [
                      {'name' => 'release-1', 'version' => '1'},
                      {'name' => 'release-1', 'version' => '2'}
                    ],
                    'stemcells' => [
                      {'name' => 'stemcell-1', 'version' => '1'},
                      {'name' => 'stemcell-2', 'version' => '1'},
                    ],
                    'cloud_config' => 'outdated',
                  },
                  {
                    'name' => 'deployment-2',
                    'releases' => [
                      {'name' => 'release-1', 'version' => '1'},
                      {'name' => 'release-2', 'version' => '1'}
                    ],
                    'stemcells' => [
                      {'name' => 'stemcell-1', 'version' => '1'},
                      {'name' => 'stemcell-1', 'version' => '2'},
                    ],
                    'cloud_config' => 'latest',
                  },
                  {
                    'name' => 'deployment-3',
                    'releases' => [],
                    'stemcells' => [],
                    'cloud_config' => 'none',
                  }
                ])
          end
        end

        describe 'getting deployment info' do
          before { basic_authorize 'reader', 'reader' }

          it 'returns manifest' do
            deployment = Models::Deployment.
                create(:name => 'test_deployment',
                       :manifest => Psych.dump({'foo' => 'bar'}))
            get '/test_deployment'

            expect(last_response.status).to eq(200)
            body = JSON.parse(last_response.body)
            expect(Psych.load(body['manifest'])).to eq('foo' => 'bar')
          end
        end

        describe 'getting deployment vms info' do
          before { basic_authorize 'reader', 'reader' }

          it 'returns a list of instances with vms (vm_cid != nil)' do
            deployment = Models::Deployment.
                create(:name => 'test_deployment',
                       :manifest => Psych.dump({'foo' => 'bar'}))

            15.times do |i|
              instance_params = {
                'deployment_id' => deployment.id,
                'job' => "job-#{i}",
                'index' => i,
                'state' => 'started',
                'uuid' => "instance-#{i}",
                'agent_id' => "agent-#{i}",
              }

              instance_params['vm_cid'] = "cid-#{i}" if i < 8
              Models::Instance.create(instance_params)
            end

            get '/test_deployment/vms'

            expect(last_response.status).to eq(200)
            body = JSON.parse(last_response.body)
            expect(body.size).to eq(8)

            body.each_with_index do |instance_with_vm, i|
              expect(instance_with_vm).to eq(
                  'agent_id' => "agent-#{i}",
                  'job' => "job-#{i}",
                  'index' => i,
                  'cid' => "cid-#{i}",
                  'id' => "instance-#{i}"
              )
            end
          end
        end

        describe 'getting deployment instances' do
          before { basic_authorize 'reader', 'reader' }

          it 'returns a list of all instances' do
            deployment = Models::Deployment.
                create(:name => 'test_deployment',
                       :manifest => Psych.dump({'foo' => 'bar'}))


            15.times do |i|
              instance_params = {
                'deployment_id' => deployment.id,
                'job' => "job-#{i}",
                'index' => i,
                'state' => 'started',
                'uuid' => "instance-#{i}",
                'agent_id' => "agent-#{i}",
              }

              Models::Instance.create(instance_params)
            end

            get '/test_deployment/instances'

            expect(last_response.status).to eq(200)
            body = JSON.parse(last_response.body)
            expect(body.size).to eq(15)

            body.each_with_index do |instance, i|
              expect(instance).to eq(
                  'agent_id' => "agent-#{i}",
                  'job' => "job-#{i}",
                  'index' => i,
                  'cid' => nil,
                  'id' => "instance-#{i}"
              )
            end
          end
        end

        describe 'property management' do

          it 'REST API for creating, updating, getting and deleting ' +
                 'deployment properties' do

            deployment = Models::Deployment.make(:name => 'mycloud')

            get '/mycloud/properties/foo'
            expect(last_response.status).to eq(404)

            get '/othercloud/properties/foo'
            expect(last_response.status).to eq(404)

            post '/mycloud/properties', JSON.generate('name' => 'foo', 'value' => 'bar'), { 'CONTENT_TYPE' => 'application/json' }
            expect(last_response.status).to eq(204)

            get '/mycloud/properties/foo'
            expect(last_response.status).to eq(200)
            expect(JSON.parse(last_response.body)['value']).to eq('bar')

            get '/othercloud/properties/foo'
            expect(last_response.status).to eq(404)

            put '/mycloud/properties/foo', JSON.generate('value' => 'baz'), { 'CONTENT_TYPE' => 'application/json' }
            expect(last_response.status).to eq(204)

            get '/mycloud/properties/foo'
            expect(JSON.parse(last_response.body)['value']).to eq('baz')

            delete '/mycloud/properties/foo'
            expect(last_response.status).to eq(204)

            get '/mycloud/properties/foo'
            expect(last_response.status).to eq(404)
          end
        end

        describe 'problem management' do
          let!(:deployment) { Models::Deployment.make(:name => 'mycloud') }
          let(:job_class) do
            Class.new(Jobs::CloudCheck::ScanAndFix) do
              define_method :perform do
                'foo'
              end
              @queue = :normal
            end
          end
          let (:db_job) { Jobs::DBJob.new(job_class, task.id, args)}

          it 'exposes problem managent REST API' do
            get '/mycloud/problems'
            expect(last_response.status).to eq(200)
            expect(JSON.parse(last_response.body)).to eq([])

            post '/mycloud/scans'
            expect_redirect_to_queued_task(last_response)

            put '/mycloud/problems', JSON.generate('solutions' => { 42 => 'do_this', 43 => 'do_that', 44 => nil }), { 'CONTENT_TYPE' => 'application/json' }
            expect_redirect_to_queued_task(last_response)

            problem = Models::DeploymentProblem.
                create(:deployment_id => deployment.id, :resource_id => 2,
                       :type => 'test', :state => 'open', :data => {})

            put '/mycloud/problems', JSON.generate('solution' => 'default'), { 'CONTENT_TYPE' => 'application/json' }
            expect_redirect_to_queued_task(last_response)
          end
        end

        describe 'resurrection' do
          let!(:deployment) { Models::Deployment.make(:name => 'mycloud') }

          def should_not_enqueue_scan_and_fix
            expect(Bosh::Director::Jobs::DBJob).not_to receive(:new).with(
              Jobs::CloudCheck::ScanAndFix,
              kind_of(Numeric),
              ['mycloud',
              [['job', 0]], false])
            expect(Delayed::Job).not_to receive(:enqueue)
            put '/mycloud/scan_and_fix', Yajl::Encoder.encode('jobs' => {'job' => [0]}), {'CONTENT_TYPE' => 'application/json'}
            expect(last_response).not_to be_redirect
          end

          def should_enqueue_scan_and_fix
            expect(Bosh::Director::Jobs::DBJob).to receive(:new).with(
              Jobs::CloudCheck::ScanAndFix,
              kind_of(Numeric),
              ['mycloud',
              [['job', 0]], false])
            expect(Delayed::Job).to receive(:enqueue)
            put '/mycloud/scan_and_fix',  JSON.generate('jobs' => {'job' => [0]}), {'CONTENT_TYPE' => 'application/json'}
            expect_redirect_to_queued_task(last_response)
          end

          context 'when global resurrection is not set' do
            it 'scans and fixes problems' do
              Models::Instance.make(deployment: deployment, job: 'job', index: 0)
              should_enqueue_scan_and_fix
            end
          end

          context 'when global resurrection is set' do
            before { Models::DirectorAttribute.make(name: 'resurrection_paused', value: resurrection_paused) }

            context 'when global resurrection is on' do
              let (:resurrection_paused) {'false'}

              it 'does not run scan_and_fix task if instances resurrection is off' do
                Models::Instance.make(deployment: deployment, job: 'job', index: 0, resurrection_paused: true)
                should_not_enqueue_scan_and_fix
              end

              it 'runs scan_and_fix task if instances resurrection is on' do
                Models::Instance.make(deployment: deployment, job: 'job', index: 0)
                should_enqueue_scan_and_fix
              end
            end

            context 'when global resurrection is off' do
              let (:resurrection_paused) {'true'}

              it 'does not run scan_and_fix task if instances resurrection is off' do
                Models::Instance.make(deployment: deployment, job: 'job', index: 0, resurrection_paused: true)
                should_not_enqueue_scan_and_fix
              end
            end
          end

          context 'when there are only ignored vms' do

            it 'does not call the resurrector' do
              Models::Instance.make(deployment: deployment, job: 'job', index: 0, resurrection_paused: false, ignore: true)

              put '/mycloud/scan_and_fix', JSON.generate('jobs' => {'job' => [0]}), {'CONTENT_TYPE' => 'application/json'}
              expect(last_response).not_to be_redirect
            end
          end
        end

        describe 'snapshots' do
          before do
            deployment = Models::Deployment.make(name: 'mycloud')

            instance = Models::Instance.make(deployment: deployment, job: 'job', index: 0, uuid: 'abc123')
            disk = Models::PersistentDisk.make(disk_cid: 'disk0', instance: instance, active: true)
            Models::Snapshot.make(persistent_disk: disk, snapshot_cid: 'snap0a')

            instance = Models::Instance.make(deployment: deployment, job: 'job', index: 1)
            disk = Models::PersistentDisk.make(disk_cid: 'disk1', instance: instance, active: true)
            Models::Snapshot.make(persistent_disk: disk, snapshot_cid: 'snap1a')
            Models::Snapshot.make(persistent_disk: disk, snapshot_cid: 'snap1b')
          end

          describe 'creating' do
            it 'should create a snapshot for a job' do
              post '/mycloud/jobs/job/1/snapshots'
              expect_redirect_to_queued_task(last_response)
            end

            it 'should create a snapshot for a deployment' do
              post '/mycloud/snapshots'
              expect_redirect_to_queued_task(last_response)
            end

            it 'should create a snapshot for a job and id' do
              post '/mycloud/jobs/job/abc123/snapshots'
              expect_redirect_to_queued_task(last_response)
            end
          end

          describe 'deleting' do
            it 'should delete all snapshots of a deployment' do
              delete '/mycloud/snapshots'
              expect_redirect_to_queued_task(last_response)
            end

            it 'should delete a snapshot' do
              delete '/mycloud/snapshots/snap1a'
              expect_redirect_to_queued_task(last_response)
            end

            it 'should raise an error if the snapshot belongs to a different deployment' do
              snap = Models::Snapshot.make(snapshot_cid: 'snap2b')
              delete "/#{snap.persistent_disk.instance.deployment.name}/snapshots/snap2a"
              expect(last_response.status).to eq(400)
            end
          end

          describe 'listing' do
            it 'should list all snapshots for a job' do
              get '/mycloud/jobs/job/0/snapshots'
              expect(last_response.status).to eq(200)
            end

            it 'should list all snapshots for a deployment' do
              get '/mycloud/snapshots'
              expect(last_response.status).to eq(200)
            end
          end
        end

        describe 'errands' do

          describe 'GET', '/:deployment_name/errands' do
            before { Config.base_dir = Dir.mktmpdir }
            after { FileUtils.rm_rf(Config.base_dir) }

            def perform
              get(
                '/fake-dep-name/errands',
                { 'CONTENT_TYPE' => 'application/json' },
              )
            end

            let!(:deployment_model) do
              Models::Deployment.make(
                name: 'fake-dep-name',
                manifest: manifest_with_errand,
                cloud_config: cloud_config
              )
            end

            context 'authenticated access' do
              before do
                authorize 'admin', 'admin'
                release = Models::Release.make(name: 'bosh-release')
                template1 = Models::Template.make(name: 'foobar', release: release)
                template2 = Models::Template.make(name: 'errand1', release: release)
                release_version = Models::ReleaseVersion.make(version: '0.1-dev', release: release)
                release_version.add_template(template1)
                release_version.add_template(template2)
              end

              it 'returns errands in deployment' do
                response = perform
                expect(response.body).to eq('[{"name":"fake-errand-name"},{"name":"another-errand"}]')
                expect(last_response.status).to eq(200)
              end

            end

            context 'accessing with invalid credentials' do
              before { authorize 'invalid-user', 'invalid-password' }
              it 'returns 401' do
                perform
                expect(last_response.status).to eq(401)
              end
            end
          end

          describe 'POST', '/:deployment_name/errands/:name/runs' do
            before { Config.base_dir = Dir.mktmpdir }
            after { FileUtils.rm_rf(Config.base_dir) }

            let!(:deployment) { Models::Deployment.make(name: 'fake-dep-name')}

            def perform(post_body)
              post(
                '/fake-dep-name/errands/fake-errand-name/runs',
                JSON.dump(post_body),
                { 'CONTENT_TYPE' => 'application/json' },
              )
            end

            context 'authenticated access' do
              before { authorize 'admin', 'admin' }

              it 'returns a task' do
                perform({})
                expect_redirect_to_queued_task(last_response)
              end

              context 'running the errand' do
                let(:task) { instance_double('Bosh::Director::Models::Task', id: 1) }
                let(:job_queue) { instance_double('Bosh::Director::JobQueue', enqueue: task) }
                before { allow(JobQueue).to receive(:new).and_return(job_queue) }

                it 'enqueues a RunErrand task' do
                  expect(job_queue).to receive(:enqueue).with(
                    'admin',
                    Jobs::RunErrand,
                    'run errand fake-errand-name from deployment fake-dep-name',
                    ['fake-dep-name', 'fake-errand-name', false],
                    deployment
                  ).and_return(task)

                  perform({})
                end

                it 'enqueues a keep-alive task' do
                  expect(job_queue).to receive(:enqueue).with(
                    'admin',
                    Jobs::RunErrand,
                    'run errand fake-errand-name from deployment fake-dep-name',
                    ['fake-dep-name', 'fake-errand-name', true],
                    deployment
                  ).and_return(task)

                  perform({'keep-alive' => true})
                end
              end
            end

            context 'accessing with invalid credentials' do
              before { authorize 'invalid-user', 'invalid-password' }

              it 'returns 401' do
                perform({})
                expect(last_response.status).to eq(401)
              end
            end
          end
        end

        describe 'diff' do
          def perform
            post(
              '/fake-dep-name/diff',
              "---\nname: fake-dep-name\nreleases: [{'name':'simple','version':5}]",
              { 'CONTENT_TYPE' => 'text/yaml' },
            )
          end
          let(:cloud_config) { Models::CloudConfig.make(manifest: {'azs' => []}) }
          let(:runtime_config) { Models::RuntimeConfig.make(manifest: {'addons' => []}) }

          before do
            Models::Deployment.create(
              :name => 'fake-dep-name',
              :manifest => Psych.dump({'jobs' => [], 'releases' => [{'name' => 'simple', 'version' => 5}]}),
              cloud_config: cloud_config,
              runtime_config: runtime_config
            )
          end

          context 'authenticated access' do
            before { authorize 'admin', 'admin' }

            it 'returns diff with resolved aliases' do
              perform
              expect(last_response.body).to eq('{"context":{"cloud_config_id":1,"runtime_config_id":1},"diff":[["jobs: []","removed"],["",null],["name: fake-dep-name","added"]]}')
            end

            it 'gives a nice error when request body is not a valid yml' do
              post '/fake-dep-name/diff', "}}}i'm not really yaml, hah!", {'CONTENT_TYPE' => 'text/yaml'}

              expect(last_response.status).to eq(400)
              expect(JSON.parse(last_response.body)['code']).to eq(440001)
              expect(JSON.parse(last_response.body)['description']).to include('Incorrect YAML structure of the uploaded manifest: ')
            end

            it 'gives a nice error when request body is empty' do
              post '/fake-dep-name/diff', '', {'CONTENT_TYPE' => 'text/yaml'}

              expect(last_response.status).to eq(400)
              expect(JSON.parse(last_response.body)).to eq(
                  'code' => 440001,
                  'description' => 'Manifest should not be empty',
              )
            end

            it 'returns 200 with an empty diff and an error message if the diffing fails' do
              allow(Bosh::Director::Manifest).to receive_message_chain(:load_from_text, :resolve_aliases)
              allow(Bosh::Director::Manifest).to receive_message_chain(:load_from_text, :diff).and_raise("Oooooh crap")

              post '/fake-dep-name/diff', {}.to_yaml, {'CONTENT_TYPE' => 'text/yaml'}

              expect(last_response.status).to eq(200)
              expect(JSON.parse(last_response.body)['diff']).to eq([])
              expect(JSON.parse(last_response.body)['error']).to include('Unable to diff manifest')
            end

            context 'when cloud config exists' do
              let(:manifest_hash) { {'jobs' => [], 'releases' => [{'name' => 'simple', 'version' => 5}], 'networks' => [{'name'=> 'non-cloudy-network'}]}}

              it 'ignores cloud config if network section exists' do
                Models::Deployment.create(
                  :name => 'fake-dep-name-no-cloud-conf',
                  :manifest => Psych.dump(manifest_hash),
                  cloud_config: nil,
                  runtime_config: runtime_config
                )

                Models::CloudConfig.make(manifest: {'networks'=>[{'name'=>'very-cloudy-network'}]})

                manifest_hash['networks'] = [{'name'=> 'network2'}]
                diff = post '/fake-dep-name-no-cloud-conf/diff', Psych.dump(manifest_hash), {'CONTENT_TYPE' => 'text/yaml'}

                expect(diff).not_to match /very-cloudy-network/
                expect(diff).to match /non-cloudy-network/
                expect(diff).to match /network2/
              end
            end
          end

          context 'accessing with invalid credentials' do
            before { authorize 'invalid-user', 'invalid-password' }

            it 'returns 401' do
              perform
              expect(last_response.status).to eq(401)
            end
          end
        end
      end

      describe 'authorization' do
        before do
          release = Models::Release.make(name: 'bosh-release')
          template1 = Models::Template.make(name: 'foobar', release: release)
          template2 = Models::Template.make(name: 'errand1', release: release)
          release_version = Models::ReleaseVersion.make(version: '0.1-dev', release: release)
          release_version.add_template(template1)
          release_version.add_template(template2)
        end

        let(:dev_team) { Models::Team.create(:name => 'dev') }
        let(:other_team) { Models::Team.create(:name => 'other') }
        let!(:owned_deployment) { Models::Deployment.create_with_teams(:name => 'owned_deployment', teams: [dev_team], manifest: manifest_with_errand('owned_deployment'), cloud_config: cloud_config) }
        let!(:other_deployment) { Models::Deployment.create_with_teams(:name => 'other_deployment', teams: [other_team], manifest: manifest_with_errand('other_deployment'), cloud_config: cloud_config) }
        describe 'when a user has dev team admin membership' do

          before {
            Models::Instance.create(:deployment => owned_deployment, :job => 'dea', :index => 0, :state => :started, :uuid => 'F0753566-CA8E-4B28-AD63-7DB3903CD98C')
            Models::Instance.create(:deployment => other_deployment, :job => 'dea', :index => 0, :state => :started, :uuid => '72652FAA-1A9C-4803-8423-BBC3630E49C6')
          }

          # dev-team-member has scopes ['bosh.teams.dev.admin']
          before { basic_authorize 'dev-team-member', 'dev-team-member' }

          context 'GET /:deployment/jobs/:job/:index_or_id' do
            it 'allows access to owned deployment' do
              expect(get('/owned_deployment/jobs/dea/0').status).to eq(200)
            end

            it 'denies access to other deployment' do
              expect(get('/other_deployment/jobs/dea/0').status).to eq(401)
            end
          end

          context 'PUT /:deployment/jobs/:job' do
            it 'allows access to owned deployment' do
              expect(put('/owned_deployment/jobs/dea', '---', { 'CONTENT_TYPE' => 'text/yaml' }).status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(put('/other_deployment/jobs/dea', nil, { 'CONTENT_TYPE' => 'text/yaml' }).status).to eq(401)
            end
          end

          context 'PUT /:deployment/jobs/:job/:index_or_id' do
            it 'allows access to owned deployment' do
              expect(put('/owned_deployment/jobs/dea/0', '---', { 'CONTENT_TYPE' => 'text/yaml' }).status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(put('/other_deployment/jobs/dea/0', '---', { 'CONTENT_TYPE' => 'text/yaml' }).status).to eq(401)
            end
          end

          context 'GET /:deployment/jobs/:job/:index_or_id/logs' do
            it 'allows access to owned deployment' do
              expect(get('/owned_deployment/jobs/dea/0/logs').status).to eq(302)
            end
            it 'denies access to other deployment' do
              expect(get('/other_deployment/jobs/dea/0/logs').status).to eq(401)
            end
          end

          context 'GET /:deployment/snapshots' do
            it 'allows access to owned deployment' do
              expect(get('/owned_deployment/snapshots').status).to eq(200)
            end
            it 'denies access to other deployment' do
              expect(get('/other_deployment/snapshots').status).to eq(401)
            end
          end

          context 'GET /:deployment/jobs/:job/:index/snapshots' do
            it 'allows access to owned deployment' do
              expect(get('/owned_deployment/jobs/dea/0/snapshots').status).to eq(200)
            end
            it 'denies access to other deployment' do
              expect(get('/other_deployment/jobs/dea/0/snapshots').status).to eq(401)
            end
          end

          context 'POST /:deployment/snapshots' do
            it 'allows access to owned deployment' do
              expect(post('/owned_deployment/snapshots').status).to eq(302)
            end
            it 'denies access to other deployment' do
              expect(post('/other_deployment/snapshots').status).to eq(401)
            end
          end

          context 'PUT /:deployment/jobs/:job/:index_or_id/resurrection' do
            it 'allows access to owned deployment' do
              expect(put('/owned_deployment/jobs/dea/0/resurrection', '{}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(200)
            end
            it 'denies access to other deployment' do
              expect(put('/other_deployment/jobs/dea/0/resurrection', '{}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(401)
            end
          end

          context 'PUT /:deployment/instance_groups/:instancegroup/:id/ignore' do
            it 'allows access to owned deployment' do
              expect(put('/owned_deployment/instance_groups/dea/F0753566-CA8E-4B28-AD63-7DB3903CD98C/ignore', '{}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(200)
            end
            it 'denies access to other deployment' do
              expect(put('/other_deployment/instance_groups/dea/72652FAA-1A9C-4803-8423-BBC3630E49C6/ignore', '{}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(401)
            end
          end

          context 'POST /:deployment/jobs/:job/:index_or_id/snapshots' do
            it 'allows access to owned deployment' do
              expect(post('/owned_deployment/jobs/dea/0/snapshots').status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(post('/other_deployment/jobs/dea/0/snapshots').status).to eq(401)
            end
          end

          context 'DELETE /:deployment/snapshots' do
            it 'allows access to owned deployment' do
              expect(delete('/owned_deployment/snapshots').status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(delete('/other_deployment/snapshots').status).to eq(401)
            end
          end

          context 'DELETE /:deployment/snapshots/:cid' do
            before do
              instance = Models::Instance.make(deployment: owned_deployment)
              persistent_disk = Models::PersistentDisk.make(instance: instance)
              Models::Snapshot.make(persistent_disk: persistent_disk, snapshot_cid: 'cid-1')
            end

            it 'allows access to owned deployment' do
              expect(delete('/owned_deployment/snapshots/cid-1').status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(delete('/other_deployment/snapshots/cid-1').status).to eq(401)
            end
          end

          context 'GET /:deployment' do
            it 'allows access to owned deployment' do
              expect(get('/owned_deployment').status).to eq(200)
            end

            it 'denies access to other deployment' do
              expect(get('/other_deployment').status).to eq(401)
            end
          end

          context 'GET /:deployment/vms' do
            it 'allows access to owned deployment' do
              expect(get('/owned_deployment/vms').status).to eq(200)
            end

            it 'denies access to other deployment' do
              expect(get('/other_deployment/vms').status).to eq(401)
            end
          end

          context 'DELETE /:deployment' do
            it 'allows access to owned deployment' do
              expect(delete('/owned_deployment').status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(delete('/other_deployment').status).to eq(401)
            end
          end

          context 'POST /:deployment/ssh' do
            it 'allows access to owned deployment' do
              expect(post('/owned_deployment/ssh', '{}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(post('/other_deployment/ssh', '{}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(401)
            end
          end

          context 'GET /:deployment/properties' do
            it 'allows access to owned deployment' do
              expect(get('/owned_deployment/properties').status).to eq(200)
            end

            it 'denies access to other deployment' do
              expect(get('/other_deployment/properties').status).to eq(401)
            end
          end

          context 'GET /:deployment/properties/:property' do
            before { Models::DeploymentProperty.make(deployment: owned_deployment, name: 'prop', value: 'value') }
            it 'allows access to owned deployment' do
              expect(get('/owned_deployment/properties/prop').status).to eq(200)
            end

            it 'denies access to other deployment' do
              expect(get('/other_deployment/properties/prop').status).to eq(401)
            end
          end

          context 'POST /:deployment/properties' do
            it 'allows access to owned deployment' do
              expect(post('/owned_deployment/properties', '{"name": "prop", "value": "bingo"}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(204)
            end

            it 'denies access to other deployment' do
              expect(post('/other_deployment/properties', '{"name": "prop", "value": "bingo"}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(401)
            end
          end

          context 'PUT /:deployment/properties/:property' do
            before { Models::DeploymentProperty.make(deployment: owned_deployment, name: 'prop', value: 'value') }
            it 'allows access to owned deployment' do
              expect(put('/owned_deployment/properties/prop', '{"value": "bingo"}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(204)
            end

            it 'denies access to other deployment' do
              expect(put('/other_deployment/properties/prop', '{"value": "bingo"}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(401)
            end
          end

          context 'DELETE /:deployment/properties/:property' do
            before { Models::DeploymentProperty.make(deployment: owned_deployment, name: 'prop', value: 'value') }
            it 'allows access to owned deployment' do
              expect(delete('/owned_deployment/properties/prop').status).to eq(204)
            end

            it 'denies access to other deployment' do
              expect(delete('/other_deployment/properties/prop').status).to eq(401)
            end
          end

          context 'POST /:deployment/scans' do
            it 'allows access to owned deployment' do
              expect(post('/owned_deployment/scans').status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(post('/other_deployment/scans').status).to eq(401)
            end
          end

          context 'GET /:deployment/problems' do
            it 'allows access to owned deployment' do
              expect(get('/owned_deployment/problems').status).to eq(200)
            end

            it 'denies access to other deployment' do
              expect(get('/other_deployment/problems').status).to eq(401)
            end
          end

          context 'PUT /:deployment/problems' do
            it 'allows access to owned deployment' do
              expect(put('/owned_deployment/problems', '{"resolutions": {}}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(put('/other_deployment/problems', '', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(401)
            end
          end

          context 'PUT /:deployment/problems' do
            it 'allows access to owned deployment' do
              expect(put('/owned_deployment/problems', '{"resolutions": {}}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(put('/other_deployment/problems', '{"resolutions": {}}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(401)
            end
          end

          context 'PUT /:deployment/scan_and_fix' do
            it 'allows access to owned deployment' do
              expect(put('/owned_deployment/scan_and_fix', '{"jobs": []}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(put('/other_deployment/scan_and_fix', '{"jobs": []}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(401)
            end
          end

          describe 'POST /' do
            it 'allows' do
              expect(post('/', manifest_with_errand, { 'CONTENT_TYPE' => 'text/yaml' }).status).to eq(302)
            end
          end

          context 'POST /:deployment/diff' do
            it 'allows access to new deployment' do
              expect(post('/new_deployment/diff', '{}', { 'CONTENT_TYPE' => 'text/yaml' }).status).to eq(200)
            end

            it 'allows access to owned deployment' do
              expect(post('/owned_deployment/diff', '{}', { 'CONTENT_TYPE' => 'text/yaml' }).status).to eq(200)
            end

            it 'denies access to other deployment' do
              expect(post('/other_deployment/diff', '{}', { 'CONTENT_TYPE' => 'text/yaml' }).status).to eq(401)
            end
          end

          context 'POST /:deployment/errands/:errand_name/runs' do
            it 'allows access to owned deployment' do
              expect(post('/owned_deployment/errands/errand_job/runs', '{}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(302)
            end

            it 'denies access to other deployment' do
              expect(post('/other_deployment/errands/errand_job/runs', '{}', { 'CONTENT_TYPE' => 'application/json' }).status).to eq(401)
            end
          end

          context 'GET /:deployment/errands' do
            it 'allows access to owned deployment' do
              expect(get('/owned_deployment/errands').status).to eq(200)
            end

            it 'denies access to other deployment' do
              expect(get('/other_deployment/errands').status).to eq(401)
            end
          end

          context 'GET /' do
            it 'allows access to owned deployments' do
              response = get('/')
              expect(response.status).to eq(200)
              expect(response.body).to include('"owned_deployment"')
              expect(response.body).to_not include('"other_deployment"')
            end
          end
        end

        describe 'when the user has bosh.read scope' do
          describe 'read endpoints' do
            before { basic_authorize 'reader', 'reader' }

            it 'allows access' do
              expect(get('/',).status).to eq(200)
              expect(get('/owned_deployment').status).to eq(200)
              expect(get('/owned_deployment/vms').status).to eq(200)
              expect(get('/no_deployment/errands').status).to eq(404)
            end
          end
        end
      end

      describe 'when the user merely has team read scope' do
        before { basic_authorize 'dev-team-read-member', 'dev-team-read-member' }
        it 'denies access to POST /' do
          expect(post('/', '{}', { 'CONTENT_TYPE' => 'text/yaml' }).status).to eq(401)
        end
      end
    end
  end
end

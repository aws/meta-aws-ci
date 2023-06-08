import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as codepipeline from 'aws-cdk-lib/aws-codepipeline';
import * as codepipeline_actions from 'aws-cdk-lib/aws-codepipeline-actions';
import {
    BuildSpec,
    ComputeType,
    FileSystemLocation,
    LinuxBuildImage,
    PipelineProject,
} from 'aws-cdk-lib/aws-codebuild';
import { IRepository } from 'aws-cdk-lib/aws-ecr';
import * as efs from 'aws-cdk-lib/aws-efs';
import { IVpc, Peer, Port, SecurityGroup } from 'aws-cdk-lib/aws-ec2';

/**
 *
 */
export interface DemosPipelineProps extends cdk.StackProps {
    readonly githubOrg?: string;
    readonly githubRepo?: string;
    readonly codestarConnectionArn: string;
    readonly imageRepo: IRepository;
    readonly imageTag?: string;
    readonly vpc: IVpc;
}

/**
 * The core pipeline stack.
 */
export class DemosPipelineStack extends cdk.Stack {
    constructor(scope: Construct, id: string, props: DemosPipelineProps) {
        super(scope, id, props);

        const sstateFilesystem = new efs.FileSystem(this, 'DemosPipelineFilesystem', {
            vpc: props.vpc,
        });
        sstateFilesystem.addAccessPoint('sstate', {
            posixUser: {
                uid: '1000',
                gid: '1000',
            },
            createAcl: {
                ownerGid: '1000',
                ownerUid: '1000',
                permissions: '0755',
            },
        });

        const sstateFilesystemId = sstateFilesystem.fileSystemId;
        const region = cdk.Stack.of(this).region;

        const projectSg = new SecurityGroup(this, 'BuildProjectSecurityGroup', {
            vpc: props.vpc,
            description: 'Security Group to allow attaching EFS',
        });
        projectSg.addIngressRule(Peer.ipv4(props.vpc.vpcCidrBlock), Port.tcp(2049), 'NFS Mount Port');
        sstateFilesystem.connections.allowFrom(projectSg, Port.tcp(2049));

        const sourceOutput = new codepipeline.Artifact();
        const sourceAction = new codepipeline_actions.CodeStarConnectionsSourceAction({
            output: sourceOutput,
            actionName: 'Demo-Source',
            repo: props.githubRepo ?? 'meta-aws-demos',
            owner: props.githubOrg ?? 'aws4embeddedlinux',
            connectionArn: props.codestarConnectionArn,
            codeBuildCloneOutput: true,
        });

        const project = new PipelineProject(this, 'DemoBuildProject', {
            buildSpec: BuildSpec.fromAsset('assets/demo/qemu/build.buildspec.yml'),
            environment: {
                computeType: ComputeType.X2_LARGE,
                buildImage: LinuxBuildImage.fromEcrRepository(props.imageRepo, props.imageTag),
                privileged: true,
            },
            timeout: cdk.Duration.hours(4),
            vpc: props.vpc,
            securityGroups: [projectSg],
            fileSystemLocations: [
                FileSystemLocation.efs({
                    identifier: 'sstate_cache',
                    location: `${sstateFilesystemId}.efs.${region}.amazonaws.com:/`,
                    mountPoint: '/sstate-cache',
                }),
            ],
        });

        // We require this dummy output to link stages.
        const buildOutput = new codepipeline.Artifact();
        const buildAction = new codepipeline_actions.CodeBuildAction({
            input: sourceOutput,
            actionName: 'Demo-Build',
            outputs: [buildOutput],
            project,
        });

        const testProject = new PipelineProject(this, 'DemoTestProject', {
            buildSpec: BuildSpec.fromAsset('assets/demo/qemu/test.buildspec.yml'),
            environment: {
                computeType: ComputeType.X2_LARGE,
                buildImage: LinuxBuildImage.fromEcrRepository(props.imageRepo, props.imageTag),
                privileged: true,
            },
            timeout: cdk.Duration.hours(4),
            securityGroups: [projectSg],
            vpc: props.vpc,
            fileSystemLocations: [
                FileSystemLocation.efs({
                    identifier: 'sstate_cache',
                    location: `${sstateFilesystemId}.efs.${region}.amazonaws.com:/`,
                    mountPoint: '/sstate-cache',
                }),
            ],
        });

        const testAction = new codepipeline_actions.CodeBuildAction({
            actionName: 'Demo-Test',
            project: testProject,
            input: buildOutput,
            type: codepipeline_actions.CodeBuildActionType.TEST,
        });

        new codepipeline.Pipeline(this, 'DemoPipeline', {
            restartExecutionOnUpdate: true,
            stages: [
                {
                    stageName: 'Source',
                    actions: [sourceAction],
                },
                {
                    stageName: 'Build',
                    actions: [buildAction],
                },
                {
                    stageName: 'Test',
                    actions: [testAction],
                },
            ],
        });
    }
}

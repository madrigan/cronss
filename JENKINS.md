# CronSS Jenkins Integration Guide

This guide explains how to use CronSS (Cron Stop/Start) in Jenkins pipelines for automated cronjob management.

## Features for Jenkins

- **Docker Support**: Manage cronjobs inside running containers (sidecars/service containers)
- **Suspend/Resume Workflow**: safely stop specific jobs and restart them later
- Environment variable support (CRON_HOST, CRON_USER, CRON_DOCKER_CONTAINER)
- JSON output for parsing in Jenkins
- Non-interactive operation
- **Local Mode**: Can manage the agent's own cronjobs using `--local`

## Environment Variables

Set these in your Jenkins job parameters or environment:

- `CRON_HOST` - SSH hostname (required, unless using `--local` or `--docker`)
- `CRON_USER` - SSH username (default: current user)
- `CRON_DOCKER_CONTAINER` - Docker container name/ID (for Docker mode)
- `CRON_STATE_NAME` - ID for suspend/resume or save/restore operations

## Jenkins Pipeline Examples

### Recommended: Suspend/Resume Workflow

This workflow is safer than full state restore as it only touches the jobs it stopped.

```groovy
pipeline {
    agent any

    environment {
        CRON_HOST = 'prod-server.example.com'
        CRON_STATE_NAME = "jenkins-${env.BUILD_ID}"
        CRON_PATTERN = 'backup|sync'
    }

    stages {
        stage('Suspend Cronjobs') {
            steps {
                script {
                    sh '''
                        cd /path/to/cronss
                        ./cronss.sh suspend "${CRON_PATTERN}" "${CRON_STATE_NAME}"
                    '''
                }
            }
        }

        stage('Deploy Application') {
            steps {
                echo 'Deploying application...'
                // Your deployment steps here
            }
        }

        stage('Resume Cronjobs') {
            steps {
                script {
                    sh '''
                        cd /path/to/cronss
                        ./cronss.sh resume "${CRON_STATE_NAME}"
                    '''
                }
            }
        }
    }

    post {
        failure {
            script {
                // Resume cronjobs even on failure
                sh '''
                    cd /path/to/cronss
                    ./cronss.sh resume "${CRON_STATE_NAME}" || true
                '''
            }
        }
    }
}
```

### Legacy: Save/Restore Workflow

Use this if you want to snapshot the entire crontab and revert to it exactly.

```groovy
    stages {
        stage('Save State') {
            steps {
                sh './cronss.sh save'
            }
        }

        stage('Stop Cronjobs') {
            steps {
                sh './cronss.sh stop-pattern "${CRON_PATTERN}"'
            }
        }

        // ... work ...

        stage('Restore Cronjobs') {
            steps {
                sh './cronss.sh restore "${CRON_STATE_NAME}"'
            }
        }
    }
```

## JSON Output

When using `--json`, commands return structured data:

### Suspend Response
```json
{
  "status": "success",
  "modified": 2,
  "action": "suspended",
  "id": "jenkins-123",
  "matched_refs": [1, 3],
  "track_file": "/path/to/.cronstate/host_user_jenkins-123.suspend"
}
```

### Resume Response
```json
{
  "status": "success",
  "modified": 2,
  "action": "resumed",
  "id": "jenkins-123",
  "matched_refs": [1, 3]
}
```

pipeline {
    agent any

    options {
        skipDefaultCheckout()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
    }

    triggers {
        pollSCM('H/2 * * * *')
    }

    environment {
        APP_NAME       = 'food-portal'
        IMAGE_REPO     = 'adityarajarora123/food-portal'
        IMAGE_TAG      = "v1.0.${env.BUILD_NUMBER}"
        TEST_CONTAINER = "food-portal-test-${env.BUILD_NUMBER}"
        LIVE_PORT      = '30092'
        PREVIEW_PORT   = '30093'
        DOCKERHUB      = credentials('dockerhub')
        KUBECONFIG     = credentials('kubeconfig')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build Image') {
            steps {
                script {
                    run "docker build --build-arg APP_VERSION=${IMAGE_TAG} -t ${IMAGE_REPO}:${IMAGE_TAG} ."
                }
            }
        }

        stage('Automated Tests') {
            steps {
                script {
                    run "docker run -d --name ${TEST_CONTAINER} ${IMAGE_REPO}:${IMAGE_TAG}"
                    run "docker exec -i ${TEST_CONTAINER} sh -s http://127.0.0.1 ${IMAGE_TAG} < ${localPath('tests/smoke-test.sh')}"
                }
            }
            post {
                always {
                    script { runStatus("docker rm -f ${TEST_CONTAINER}") }
                }
            }
        }

        stage('Push Image') {
            steps {
                script {
                    dockerLogin()
                    run "docker push ${IMAGE_REPO}:${IMAGE_TAG}"
                }
            }
        }

        stage('Resolve Environments') {
            steps {
                script {
                    ensureService(APP_NAME, 'service.yaml')
                    ensureService("${APP_NAME}-preview", 'service-preview.yaml')
                    env.LIVE_COLOUR = capture("kubectl get service ${APP_NAME} -o \"jsonpath={.spec.selector.version}\"")
                    env.IDLE_COLOUR = env.LIVE_COLOUR == 'blue' ? 'green' : 'blue'
                    echo "Live environment: ${env.LIVE_COLOUR} | Release ${IMAGE_TAG} will be deployed to: ${env.IDLE_COLOUR}"
                }
            }
        }

        stage('Deploy to Idle Environment') {
            steps {
                script {
                    String deployment = "${APP_NAME}-${env.IDLE_COLOUR}"
                    renderManifest("deployment-${env.IDLE_COLOUR}.yaml", "deployment-${env.IDLE_COLOUR}.rendered.yaml")
                    run "kubectl apply -f deployment-${env.IDLE_COLOUR}.rendered.yaml"
                    if (runStatus("kubectl rollout status deployment/${deployment} --timeout=120s") != 0) {
                        rollbackIdle(deployment)
                        error "Release ${IMAGE_TAG} did not become healthy in the ${env.IDLE_COLOUR} environment. Live traffic remains on ${env.LIVE_COLOUR}."
                    }
                }
            }
        }

        stage('Validate Idle Environment') {
            steps {
                script {
                    String deployment = "${APP_NAME}-${env.IDLE_COLOUR}"
                    run "kubectl set selector service ${APP_NAME}-preview app=${APP_NAME},version=${env.IDLE_COLOUR}"
                    sleep time: 5, unit: 'SECONDS'
                    int status = runStatus("kubectl exec -i deployment/${deployment} -- sh -s http://${APP_NAME}-preview ${IMAGE_TAG} < ${localPath('tests/smoke-test.sh')}")
                    if (status != 0) {
                        rollbackIdle(deployment)
                        error "Release ${IMAGE_TAG} failed validation on the preview service. Live traffic remains on ${env.LIVE_COLOUR}."
                    }
                }
            }
        }

        stage('Switch Traffic') {
            steps {
                script {
                    run "kubectl set selector service ${APP_NAME} app=${APP_NAME},version=${env.IDLE_COLOUR}"
                    sleep time: 5, unit: 'SECONDS'
                    int status = runStatus("kubectl exec -i deployment/${APP_NAME}-${env.IDLE_COLOUR} -- sh -s http://${APP_NAME} ${IMAGE_TAG} < ${localPath('tests/smoke-test.sh')}")
                    if (status != 0) {
                        run "kubectl set selector service ${APP_NAME} app=${APP_NAME},version=${env.LIVE_COLOUR}"
                        error "Live verification of ${IMAGE_TAG} failed. Traffic switched back to ${env.LIVE_COLOUR}."
                    }
                    echo "Traffic switched: ${env.LIVE_COLOUR} -> ${env.IDLE_COLOUR}"
                }
            }
        }

        stage('Promote Stable Release') {
            steps {
                script {
                    run "docker tag ${IMAGE_REPO}:${IMAGE_TAG} ${IMAGE_REPO}:stable"
                    run "docker tag ${IMAGE_REPO}:${IMAGE_TAG} ${IMAGE_REPO}:latest"
                    run "docker push ${IMAGE_REPO}:stable"
                    run "docker push ${IMAGE_REPO}:latest"
                    run "kubectl get deployments,pods,services -l app=${APP_NAME} -o wide"
                }
            }
        }
    }

    post {
        success {
            echo "Release ${IMAGE_TAG} is live (${env.IDLE_COLOUR}) at http://localhost:${LIVE_PORT}. Previous release kept on standby (${env.LIVE_COLOUR})."
        }
        failure {
            echo "Pipeline failed for release ${IMAGE_TAG}. Users continue to be served by the ${env.LIVE_COLOUR ?: 'current'} environment."
        }
        always {
            script { runStatus('docker logout') }
        }
    }
}

def run(String command) {
    if (isUnix()) {
        sh command
    } else {
        bat command
    }
}

def runStatus(String command) {
    return isUnix() ? sh(script: command, returnStatus: true) : bat(script: command, returnStatus: true)
}

def capture(String command) {
    String output = isUnix() ? sh(script: command, returnStdout: true) : bat(script: "@${command}", returnStdout: true)
    return output.trim()
}

def localPath(String path) {
    return isUnix() ? path : path.replace('/', '\\')
}

def dockerLogin() {
    if (isUnix()) {
        sh 'echo "$DOCKERHUB_PSW" | docker login -u "$DOCKERHUB_USR" --password-stdin'
    } else {
        bat '@echo %DOCKERHUB_PSW%| docker login -u %DOCKERHUB_USR% --password-stdin'
    }
}

def ensureService(String name, String manifest) {
    if (!capture("kubectl get service ${name} --ignore-not-found -o name")) {
        run "kubectl apply -f ${manifest}"
    }
}

def renderManifest(String source, String target) {
    String manifest = readFile(source)
        .replace("${env.IMAGE_REPO}:latest", "${env.IMAGE_REPO}:${env.IMAGE_TAG}")
        .replace('Initial release', "Build #${env.BUILD_NUMBER} - ${env.IMAGE_TAG}")
    writeFile file: target, text: manifest
}

def rollbackIdle(String deployment) {
    echo "Release ${env.IMAGE_TAG} failed in ${deployment}. Collecting diagnostics and restoring its previous revision."
    runStatus("kubectl get pods -l app=${env.APP_NAME} -o wide")
    runStatus('kubectl get events --field-selector type=Warning --sort-by=.lastTimestamp')
    if (runStatus("kubectl rollout undo deployment/${deployment}") == 0) {
        run "kubectl rollout status deployment/${deployment} --timeout=120s"
        run "kubectl rollout history deployment/${deployment}"
    } else {
        echo "${deployment} has no earlier revision; scaling it down."
        run "kubectl scale deployment/${deployment} --replicas=0"
    }
    run "kubectl get service ${env.APP_NAME} -o wide"
}

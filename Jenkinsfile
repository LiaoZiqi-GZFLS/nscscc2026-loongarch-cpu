pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
    }

    parameters {
        booleanParam(name: 'RUN_VIVADO_CHECK', defaultValue: true, description: 'Run Vivado RTL elaboration and DRC')
        booleanParam(name: 'BUILD_UCORE', defaultValue: false, description: 'Build the uCore image')
        booleanParam(name: 'BUILD_LINUX', defaultValue: false, description: 'Build the board-16m Linux image')
        string(name: 'BUILD_JOBS', defaultValue: '2', description: 'Parallel jobs for optional Linux build')
    }

    environment {
        LC_ALL = 'C.UTF-8'
        TOOLCHAIN_BIN = '/home/cjy/chiplab/toolchains/loongarch32r-linux-gnusf-2022-05-20/bin'
        PATH = "/tools/Xilinx/Vivado/2023.2/bin:${TOOLCHAIN_BIN}:${env.PATH}"
    }

    stages {
        stage('Submission Check') {
            steps {
                sh 'chmod +x ci/local-ci.sh && ci/local-ci.sh layout'
            }
        }

        stage('Boot Build') {
            steps {
                sh 'ci/local-ci.sh boot'
            }
        }

        stage('Vivado RTL Check') {
            when {
                expression { params.RUN_VIVADO_CHECK }
            }
            steps {
                sh 'ci/local-ci.sh vivado'
            }
        }

        stage('uCore Build') {
            when {
                expression { params.BUILD_UCORE }
            }
            steps {
                sh 'ci/local-ci.sh ucore'
            }
        }

        stage('Linux Build') {
            when {
                expression { params.BUILD_LINUX }
            }
            steps {
                sh 'ci/local-ci.sh linux'
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'sw/boot/boot.elf,sw/boot/boot.bin,.ci-work/**/*.rpt,sw/ucore/out/**,sw/linux/out/**', allowEmptyArchive: true
        }
    }
}

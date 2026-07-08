const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const viewRoot = path.resolve(__dirname, '..', '..')

test('qml project installs the guardian gateway beside the app', () => {
  const pro = fs.readFileSync(path.join(viewRoot, 'QT_project/QML_version/qml/qml.pro'), 'utf8')
  assert.match(pro, /guardianGateway\.files/)
  assert.match(pro, /guardian_gateway/)
})

test('board launcher starts one guardian gateway with its own log', () => {
  const script = fs.readFileSync(path.join(viewRoot, 'run_qml.sh'), 'utf8')
  assert.match(script, /guardian_gateway\/server\.py/)
  assert.match(script, /guardian_gateway\.log/)
  assert.match(script, /pkill -f.*guardian_gateway\/server\.py/)
})

test('board launcher kills only the qml binary and not run_qml.sh itself', () => {
  const script = fs.readFileSync(path.join(viewRoot, 'run_qml.sh'), 'utf8')
  assert.match(script, /pkill -9 -x qml/)
  assert.doesNotMatch(script, /pkill -9 qml/)
})

test('hidden home Scene3D is not continuously driven by IMU updates', () => {
  const qml = fs.readFileSync(
    path.join(viewRoot, 'QT_project/QML_version/qml/main.qml'), 'utf8')
  assert.match(qml, /property bool homePageActive: activeNavIndex === 0/)
  const guardedBindings = qml.match(
    /root\.homePageActive && root\.imu3DLinked && imuService\.available/g) || []
  assert.equal(guardedBindings.length, 3)
})

test('board launcher handles Ctrl+C without leaving noisy jobs or a broken terminal', () => {
  const script = fs.readFileSync(path.join(viewRoot, 'run_qml.sh'), 'utf8')
  assert.match(script, /qml_pid=\$!/)
  assert.match(script, /on_interrupt\(\)/)
  assert.match(script, /trap on_interrupt INT TERM/)
  assert.match(script, /trap - INT TERM EXIT/)
  assert.match(script, /kill -9 "\$qml_pid"/)
  assert.match(script, /wait "\$qml_pid" 2>\/dev\/null \|\| true/)
  assert.match(script, /stty sane 2>\/dev\/null \|\| true/)
  assert.doesNotMatch(script, /trap 'exit 130' INT TERM/)
})

test('board launcher detects serial Ctrl+C bytes and restores the exact tty state', () => {
  const script = fs.readFileSync(path.join(viewRoot, 'run_qml.sh'), 'utf8')
  assert.match(script, /terminal_state=\$\(stty -g/)
  assert.match(script, /stty -isig -icanon -echo min 1 time 0/)
  assert.match(script, /watch_for_ctrl_c\(\)/)
  assert.match(script, /\$'\\003'/)
  assert.match(script, /kill -TERM "\$\$"/)
  assert.match(script, /stty "\$terminal_state"/)
  const detachedInputs = script.match(/< \/dev\/null &/g) || []
  assert.equal(detachedInputs.length, 2)
})

test('guardian integration leaves the original IMU calibration state machine unchanged', () => {
  const qmlRoot = path.join(viewRoot, 'QT_project/QML_version/qml')
  const header = fs.readFileSync(path.join(qmlRoot, 'imuprocessor.h'), 'utf8')
  const processor = fs.readFileSync(path.join(qmlRoot, 'imuprocessor.cpp'), 'utf8')
  const service = fs.readFileSync(path.join(qmlRoot, 'imuservice.cpp'), 'utf8')

  assert.match(header, /void startCalibration\(\);/)
  assert.doesNotMatch(header, /calibrationWarmup|calibrationRetries/)
  assert.doesNotMatch(processor, /calibrationWarmup|calibrationRetries/)
  assert.doesNotMatch(service, /startCalibration\([^)]/)
})

test('production IMU calibration uses the supported fast startup sample count', () => {
  const qmlRoot = path.join(viewRoot, 'QT_project/QML_version/qml')
  const config = JSON.parse(fs.readFileSync(
    path.join(qmlRoot, 'assets/config/cockpit-imu.json'), 'utf8'))
  const types = fs.readFileSync(path.join(qmlRoot, 'imutypes.h'), 'utf8')

  assert.equal(config.calibration.samples, 20)
  assert.match(types, /calibrationSampleCount = 20;/)

  const launcher = fs.readFileSync(path.join(viewRoot, 'run_qml.sh'), 'utf8')
  assert.match(launcher, /IMU_CONFIG="\/opt\/qml\/bin\/assets\/config\/cockpit-imu\.json"/)
  assert.match(launcher, /install -D -m 644 "\$IMU_CONFIG_SOURCE" "\$IMU_CONFIG"/)
  assert.match(launcher, /COCKPIT_IMU_CONFIG="\$IMU_CONFIG"/)
})

test('guardian sidecar is isolated from the IMU device and publishes non-blocking datagrams', () => {
  const qmlRoot = path.join(viewRoot, 'QT_project/QML_version/qml')
  const publisher = fs.readFileSync(path.join(qmlRoot, 'guardianeventpublisher.cpp'), 'utf8')
  const service = fs.readFileSync(path.join(qmlRoot, 'imuservice.cpp'), 'utf8')
  const gatewayRoot = path.join(viewRoot, 'guardian_gateway')
  const gateway = ['protocol.py', 'server.py', 'state.py']
    .map(name => fs.readFileSync(path.join(gatewayRoot, name), 'utf8')).join('\n')
  const appSources = [
    'config.js',
    'models/guardian-state.js',
    'services/guardian-socket.js',
    'services/guardian-storage.js'
  ].map(name => fs.readFileSync(path.join(viewRoot, 'app', name), 'utf8')).join('\n')

  assert.doesNotMatch(gateway, /\/dev\/mpu6050|COCKPIT_IMU_DEVICE/)
  assert.doesNotMatch(appSources, /\/dev\/mpu6050|COCKPIT_IMU_DEVICE/)
  assert.match(publisher, /AF_UNIX/)
  assert.match(publisher, /SOCK_DGRAM/)
  assert.match(publisher, /MSG_DONTWAIT/)
  const guardianEmits = service.match(/emit guardianCriticalEvent/g) || []
  assert.equal(guardianEmits.length, 1)
  assert.ok(service.indexOf('emit guardianCriticalEvent') >
    service.indexOf('void ImuService::postEvents'))
})

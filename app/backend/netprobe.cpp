#include "netprobe.h"

#include <QElapsedTimer>
#include <QSettings>
#include <QHostAddress>
#include <QHostInfo>
#include <QMetaObject>
#include <QTcpSocket>
#include <QUdpSocket>
#include <QtEndian>

#include <algorithm>
#include <thread>
#include <vector>

static const quint16 PROBE_PORT = 47800;

NetProbe::NetProbe(QObject* parent) : QObject(parent) {}

NetProbe::~NetProbe()
{
    cancel();
    if (m_Thread) {
        m_Thread->wait(3000);
    }
}

void NetProbe::setPhase(int p)
{
    QMetaObject::invokeMethod(this, [this, p] { m_Phase = p; m_Live = 0; emit phaseChanged(); emit liveChanged(); }, Qt::QueuedConnection);
}

void NetProbe::setProgress(double p)
{
    QMetaObject::invokeMethod(this, [this, p] { m_Progress = p; emit progressChanged(); }, Qt::QueuedConnection);
}

void NetProbe::setLive(double v)
{
    QMetaObject::invokeMethod(this, [this, v] { m_Live = v; emit liveChanged(); }, Qt::QueuedConnection);
}

void NetProbe::start(const QString& host)
{
    if (m_Running) return;
    if (m_Thread) { m_Thread->wait(); m_Thread->deleteLater(); m_Thread = nullptr; }
    m_Cancel = false;
    m_Running = true;
    m_Phase = -1;
    m_Progress = 0;
    emit runningChanged();
    emit phaseChanged();
    emit progressChanged();
    m_Thread = QThread::create([this, host] { run(host); });
    m_Thread->start();
}

void NetProbe::cancel()
{
    m_Cancel = true;
}

static double median(std::vector<double> v)
{
    std::sort(v.begin(), v.end());
    size_t n = v.size();
    return n % 2 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2.0;
}

static QByteArray packet(quint32 seq, int size)
{
    QByteArray b(qMax(16, size), '\0');
    memcpy(b.data(), "NPRB", 4);
    qToBigEndian<quint32>(seq, b.data() + 4);
    return b;
}

void NetProbe::run(QString host)
{
    auto fail = [this](const QString& msg) {
        QMetaObject::invokeMethod(this, [this, msg] { m_Running = false; emit runningChanged(); emit failed(msg); }, Qt::QueuedConnection);
    };
    auto stopped = [this] {
        QMetaObject::invokeMethod(this, [this] { m_Running = false; emit runningChanged(); }, Qt::QueuedConnection);
    };

    QHostAddress addr(host);
    if (addr.isNull()) {
        QHostInfo hi = QHostInfo::fromName(host);
        for (const QHostAddress& a : hi.addresses()) {
            if (a.protocol() == QAbstractSocket::IPv4Protocol) { addr = a; break; }
        }
    }
    if (addr.isNull()) { fail(tr("No pudimos encontrar el servidor de pruebas. Revisa tu conexión a internet.")); return; }

    QUdpSocket sock;
    sock.bind(QHostAddress::AnyIPv4, 0);

    // 1) latencia
    setPhase(0);
    std::vector<double> rtts;
    for (int i = 0; i < 40 && !m_Cancel; i++) {
        QElapsedTimer t;
        t.start();
        sock.writeDatagram(packet(i, 64), addr, PROBE_PORT);
        while (t.elapsed() < 400 && !m_Cancel) {
            if (!sock.waitForReadyRead(int(400 - t.elapsed()))) break;
            bool hit = false;
            while (sock.hasPendingDatagrams()) {
                QByteArray d(int(sock.pendingDatagramSize()), '\0');
                sock.readDatagram(d.data(), d.size());
                if (d.size() >= 16 && qFromBigEndian<quint32>(d.constData() + 4) == quint32(i)) hit = true;
            }
            if (hit) { rtts.push_back(t.nsecsElapsed() / 1e6); setLive(median(rtts)); break; }
        }
        setProgress(0.15 * (i + 1) / 40.0);
        QThread::msleep(50);
    }
    if (m_Cancel) { stopped(); return; }
    if (rtts.empty()) {
        fail(tr("No pudimos llegar al servidor de pruebas de Nova Play. Revisa que tengas internet; si estás en una red de empresa o universidad, puede que bloquee los juegos en la nube."));
        return;
    }
    double latency = median(rtts);

    // 2) perdida y variacion: 400 paquetes de 1000 bytes a 100 por segundo
    setPhase(1);
    const int total = 400;
    std::vector<qint64> sentAt(total, 0);
    std::vector<double> rtt(total, -1);
    QElapsedTimer clock;
    clock.start();
    auto drain = [&] {
        while (sock.hasPendingDatagrams()) {
            QByteArray d(int(sock.pendingDatagramSize()), '\0');
            sock.readDatagram(d.data(), d.size());
            if (d.size() < 16 || d.at(0) != 'N') continue;
            quint32 seq = qFromBigEndian<quint32>(d.constData() + 4);
            if (seq >= 1000 && seq < 1000 + quint32(total) && rtt[seq - 1000] < 0) rtt[seq - 1000] = (clock.nsecsElapsed() - sentAt[seq - 1000]) / 1e6;
        }
    };
    for (int i = 0; i < total && !m_Cancel; i++) {
        qint64 due = qint64(i) * 10000000LL;
        while (clock.nsecsElapsed() < due) {
            sock.waitForReadyRead(int(qMax<qint64>(1, (due - clock.nsecsElapsed()) / 1000000)));
            drain();
        }
        sentAt[i] = clock.nsecsElapsed();
        sock.writeDatagram(packet(1000 + i, 1000), addr, PROBE_PORT);
        drain();
        if (i % 20 == 19) {
            int ok = 0;
            for (int k = 0; k <= i; k++) if (rtt[k] >= 0) ok++;
            setLive(100.0 * (i + 1 - ok) / (i + 1));
            setProgress(0.15 + 0.35 * (i + 1) / total);
        }
    }
    QElapsedTimer tail;
    tail.start();
    while (tail.elapsed() < 1000 && !m_Cancel) { sock.waitForReadyRead(100); drain(); }
    if (m_Cancel) { stopped(); return; }
    int ok = 0, jn = 0;
    double js = 0, prev = -1;
    for (int i = 0; i < total; i++) {
        if (rtt[i] < 0) continue;
        ok++;
        if (prev >= 0) { js += qAbs(rtt[i] - prev); jn++; }
        prev = rtt[i];
    }
    double loss = 100.0 * (total - ok) / total;
    double jitter = jn ? js / jn : 0;

    // 3) ancho de banda
    setPhase(2);
    double mbps = bandwidth(addr.toString());
    if (m_Cancel) { stopped(); return; }
    if (mbps < 0.1) {
        fail(tr("No pudimos medir la velocidad de descarga: la conexión con el servidor de pruebas se cortó. Inténtalo de nuevo en un momento."));
        return;
    }
    setProgress(1.0);

    QVariantMap r;
    r["latencyMs"] = latency;
    r["jitterMs"] = jitter;
    r["lossPct"] = loss;
    r["mbps"] = mbps;
    r["sent"] = total;
    r["received"] = ok;
    // calidad recomendada (mismos criterios que Android)
    if (!(mbps < 15 || loss >= 4.0 || latency >= 150)) {
        int kbps = int(qBound(5000.0, qRound(mbps * 0.6) * 1000.0, 40000.0));
        QVariantMap q;
        if (mbps >= 35 && loss < 2.0) { q["width"] = 1920; q["height"] = 1080; q["fps"] = 60; q["kbps"] = kbps; }
        else if (mbps >= 25 && loss < 2.0) { q["width"] = 1920; q["height"] = 1080; q["fps"] = 60; q["kbps"] = qMin(kbps, 15000); }
        else { q["width"] = 1280; q["height"] = 720; q["fps"] = 60; q["kbps"] = qMin(kbps, 10000); }
        r["quality"] = q;
        // el menu de ajustes de la transmision ofrece «Usar lo recomendado por mi red» con este resultado
        QSettings st;
        st.setValue("novaplay/red/width", q["width"]);
        st.setValue("novaplay/red/height", q["height"]);
        st.setValue("novaplay/red/fps", q["fps"]);
        st.setValue("novaplay/red/kbps", q["kbps"]);
        st.setValue("novaplay/red/mbps", mbps);
    }
    QMetaObject::invokeMethod(this, [this, r] { m_Running = false; emit runningChanged(); emit finished(r); }, Qt::QueuedConnection);
}

double NetProbe::bandwidth(const QString& host)
{
    const int streams = 4;
    const qint64 durationMs = 6000, warmMs = 1000;
    std::atomic<qint64> bytes{0};
    std::atomic<bool> stop{false};
    std::vector<std::thread> threads;
    for (int s = 0; s < streams; s++) {
        threads.emplace_back([&, host] {
            QTcpSocket t;
            t.connectToHost(host, PROBE_PORT);
            if (!t.waitForConnected(5000)) return;
            t.write("GET /down?s=7 HTTP/1.1\r\nHost: " + host.toLatin1() + "\r\nConnection: close\r\n\r\n");
            t.flush();
            bool headerDone = false;
            QByteArray head;
            while (!stop && !m_Cancel) {
                if (!t.waitForReadyRead(5000)) break;
                QByteArray d = t.readAll();
                if (!headerDone) {
                    head += d;
                    int at = head.indexOf("\r\n\r\n");
                    if (at < 0) continue;
                    headerDone = true;
                    bytes += head.size() - at - 4;
                } else {
                    bytes += d.size();
                }
            }
            t.abort();
        });
    }
    QElapsedTimer el;
    el.start();
    qint64 warmBytes = -1;
    QElapsedTimer warm;
    double mbps = 0;
    while (!m_Cancel) {
        QThread::msleep(250);
        qint64 b = bytes;
        if (el.elapsed() >= warmMs && warmBytes < 0) { warmBytes = b; warm.start(); }
        if (warmBytes >= 0) {
            double secs = warm.elapsed() / 1000.0;
            if (secs > 0.2) mbps = (b - warmBytes) * 8 / 1e6 / secs;
        } else if (el.elapsed() > 0) {
            mbps = b * 8 / 1e6 / (el.elapsed() / 1000.0);
        }
        setLive(mbps);
        setProgress(0.5 + 0.5 * qMin(1.0, el.elapsed() / double(durationMs)));
        if (el.elapsed() >= durationMs) break;
    }
    stop = true;
    for (auto& t : threads) t.join();
    return mbps;
}

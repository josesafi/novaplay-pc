#pragma once

#include <QObject>
#include <QThread>
#include <QVariantMap>
#include <atomic>

/**
 * «Prueba de red» de Nova Play (igual que la app de Android, com/limelight/nova/NetProbe.java): mide contra el servidor de pruebas
 * que esta junto a las consolas (nova-play-netprobe, puerto 47800) la latencia (40 paquetes UDP), la perdida y la variacion (400
 * paquetes UDP de 1000 bytes a 100 por segundo, como el video) y el ancho de banda (4 descargas TCP de 6 s). Corre en otro hilo; la
 * pantalla (NetTest.qml) solo lee sus propiedades y recibe el resultado.
 */
class NetProbe : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    Q_PROPERTY(int phase READ phase NOTIFY phaseChanged)
    Q_PROPERTY(double progress READ progress NOTIFY progressChanged)
    Q_PROPERTY(double live READ live NOTIFY liveChanged)

public:
    explicit NetProbe(QObject* parent = nullptr);
    ~NetProbe() override;

    bool running() const { return m_Running; }
    int phase() const { return m_Phase; }
    double progress() const { return m_Progress; }
    double live() const { return m_Live; }

    Q_INVOKABLE void start(const QString& host);
    Q_INVOKABLE void cancel();

signals:
    void runningChanged();
    void phaseChanged();
    void progressChanged();
    void liveChanged();
    /** latencyMs, jitterMs, lossPct, mbps, sent, received, quality {width,height,fps,kbps} (vacio si no alcanza) */
    void finished(QVariantMap result);
    void failed(QString message);

private:
    void run(QString host);
    void setPhase(int p);
    void setProgress(double p);
    void setLive(double v);
    double bandwidth(const QString& host);

    QThread* m_Thread = nullptr;
    std::atomic<bool> m_Cancel{false};
    bool m_Running = false;
    int m_Phase = -1;
    double m_Progress = 0;
    double m_Live = 0;
};

#include "novaapi.h"

#include <QJSEngine>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSettings>
#include <QUrl>

// Direccion de la API de Nova Play (la misma del panel). Para pruebas se puede cambiar con la variable NOVAPLAY_API.
static QString apiBase()
{
    QByteArray env = qgetenv("NOVAPLAY_API");
    return env.isEmpty() ? QStringLiteral("https://api.novawebcolombia.com") : QString::fromUtf8(env);
}

static const QByteArray kSessionCookie = QByteArrayLiteral("__Host-novacloud_session");

NovaApi::NovaApi(QObject* parent) : QObject(parent)
{
    loadSession();
}

void NovaApi::loadSession()
{
    QSettings s;
    m_Session = s.value("novaplay/session").toString();
    m_Csrf = s.value("novaplay/csrf").toString();
    m_FirstName = s.value("novaplay/firstName").toString();
    m_Email = s.value("novaplay/email").toString();
}

void NovaApi::saveSession()
{
    QSettings s;
    s.setValue("novaplay/session", m_Session);
    s.setValue("novaplay/csrf", m_Csrf);
    s.setValue("novaplay/firstName", m_FirstName);
    s.setValue("novaplay/email", m_Email);
    emit sessionChanged();
}

void NovaApi::takeSessionCookie(QNetworkReply* reply)
{
    const QByteArray prefix = kSessionCookie + "=";
    for (const auto& pair : reply->rawHeaderPairs()) {
        if (pair.first.compare("Set-Cookie", Qt::CaseInsensitive) != 0) {
            continue;
        }
        // Qt junta varias cookies de la misma respuesta con saltos de linea
        for (const QByteArray& line : pair.second.split('\n')) {
            int at = line.indexOf(prefix);
            if (at < 0) {
                continue;
            }
            QByteArray value = line.mid(at + prefix.size());
            int end = value.indexOf(';');
            if (end >= 0) {
                value = value.left(end);
            }
            if (!value.isEmpty()) {
                m_Session = QString::fromUtf8(value);
            }
        }
    }
}

QString NovaApi::errorMessage(int status, const QVariant& body)
{
    // la API responde { error: { code, message } } o { message }
    QVariantMap m = body.toMap();
    QString msg = m.value("error").toMap().value("message").toString();
    if (msg.isEmpty()) {
        msg = m.value("message").toString();
    }
    if (!msg.isEmpty()) {
        return msg;
    }
    if (status == 0) {
        return tr("No hay conexión con Nova Play. Revisa tu internet e inténtalo de nuevo.");
    }
    if (status == 401) {
        return tr("Correo o contraseña incorrectos.");
    }
    if (status == 429) {
        return tr("Demasiados intentos. Espera unos minutos e inténtalo de nuevo.");
    }
    return tr("Algo salió mal (código %1). Inténtalo de nuevo.").arg(status);
}

void NovaApi::send(const QByteArray& method, const QString& path, const QVariant& body, bool authed, Done done)
{
    QNetworkRequest req(QUrl(apiBase() + path));
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setRawHeader("Accept", "application/json");
    req.setRawHeader("User-Agent", "NovaPlay-PC");
    if (authed && !m_Session.isEmpty()) {
        req.setRawHeader("Cookie", kSessionCookie + "=" + m_Session.toUtf8());
        if (!m_Csrf.isEmpty()) {
            req.setRawHeader("X-CSRF-Token", m_Csrf.toUtf8());
        }
    }
    QByteArray payload;
    if (body.isValid() && !body.isNull()) {
        payload = QJsonDocument::fromVariant(body).toJson(QJsonDocument::Compact);
    }
    QNetworkReply* reply = m_Nam.sendCustomRequest(req, method, payload);
    connect(reply, &QNetworkReply::finished, this, [this, reply, authed, done]() {
        reply->deleteLater();
        int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        QVariant parsed = QJsonDocument::fromJson(reply->readAll()).toVariant();
        takeSessionCookie(reply);
        if (authed && status == 401 && !m_Session.isEmpty()) {
            // sesion vencida o cerrada desde el panel: se olvida y la app vuelve a la pantalla de inicio de sesion
            m_Session.clear();
            m_Csrf.clear();
            saveSession();
            emit sessionExpired();
        }
        if (done) {
            done(status, parsed);
        }
    });
}

void NovaApi::callJs(QJSValue callback, const QJSValueList& args)
{
    if (callback.isCallable()) {
        callback.call(args);
    }
}

void NovaApi::finishLogin(const QVariant& body, QJSValue callback)
{
    m_Csrf = body.toMap().value("csrfToken").toString();
    // nombre para el saludo
    send("GET", "/api/v1/auth/session", QVariant(), true, [this, callback](int, const QVariant& s) {
        QVariantMap user = s.toMap().value("user").toMap();
        m_FirstName = user.value("firstName").toString();
        if (!user.value("email").toString().isEmpty()) {
            m_Email = user.value("email").toString();
        }
        QString csrf = s.toMap().value("csrfToken").toString();
        if (!csrf.isEmpty()) {
            m_Csrf = csrf;
        }
        saveSession();
        callJs(callback, { QJSValue(true), QJSValue(false), QJSValue(QString()) });
    });
}

void NovaApi::login(QString email, QString password, QJSValue callback)
{
    m_Email = email.trimmed();
    m_Session.clear();
    QVariantMap body{{"email", m_Email}, {"password", password}};
    send("POST", "/api/v1/auth/login", body, false, [this, callback](int status, const QVariant& r) {
        if (status != 200 && status != 201) {
            callJs(callback, { QJSValue(false), QJSValue(false), QJSValue(errorMessage(status, r)) });
            return;
        }
        QVariantMap m = r.toMap();
        if (m.value("twoFactorRequired").toBool()) {
            m_Challenge = m.value("challengeId").toString();
            callJs(callback, { QJSValue(true), QJSValue(true), QJSValue(QString()) });
            return;
        }
        if (m_Session.isEmpty()) {
            callJs(callback, { QJSValue(false), QJSValue(false), QJSValue(tr("No se pudo iniciar la sesión. Inténtalo de nuevo.")) });
            return;
        }
        finishLogin(r, callback);
    });
}

void NovaApi::loginTwoFactor(QString code, QJSValue callback)
{
    QString clean = code.trimmed().remove(' ');
    // 6 digitos = codigo de la app autenticadora; otra cosa = codigo de recuperacion
    bool totp = QRegularExpression(QStringLiteral("^[0-9]{6}$")).match(clean).hasMatch();
    QVariantMap body{{"challengeId", m_Challenge}, {totp ? "code" : "recoveryCode", clean}};
    send("POST", "/api/v1/auth/login/2fa", body, false, [this, callback](int status, const QVariant& r) {
        if ((status != 200 && status != 201) || m_Session.isEmpty()) {
            callJs(callback, { QJSValue(false), QJSValue(false), QJSValue(errorMessage(status, r)) });
            return;
        }
        finishLogin(r, callback);
    });
}

void NovaApi::logout()
{
    if (!m_Session.isEmpty()) {
        send("POST", "/api/v1/auth/logout", QVariantMap(), true, nullptr);
    }
    m_Session.clear();
    m_Csrf.clear();
    m_FirstName.clear();
    saveSession();
}

void NovaApi::get(QString path, QJSValue callback)
{
    send("GET", path, QVariant(), true, [this, callback](int status, const QVariant& body) {
        callJs(callback, { QJSValue(status), m_Engine ? m_Engine->toScriptValue(body) : QJSValue() });
    });
}

void NovaApi::post(QString path, QVariant body, QJSValue callback)
{
    send("POST", path, body, true, [this, callback](int status, const QVariant& r) {
        callJs(callback, { QJSValue(status), m_Engine ? m_Engine->toScriptValue(r) : QJSValue() });
    });
}

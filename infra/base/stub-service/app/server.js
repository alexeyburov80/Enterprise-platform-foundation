// Заглушка модуля MES (принцип 6 ТЗ: "MVP + заглушки").
// Контракт API соответствует будущей реальной реализации MES —
// остальные модули интегрируются с этим стабом так же, как с настоящим
// сервисом, и не заметят подмены, когда стаб заменят на реальный код.
//
// Реальная реализация должна отдавать те же поля по тем же путям,
// подключаясь к реальным данным вместо захардкоженных значений ниже.

const express = require('express');
const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;

// GET /api/mes/dispatch/orders — список заказов в диспетчеризации склад<->производство
app.get('/api/mes/dispatch/orders', (_req, res) => {
  res.json({
    orders: [
      { orderId: 'STUB-001', status: 'in_production', batchId: 'B-001' },
      { orderId: 'STUB-002', status: 'queued', batchId: 'B-002' },
    ],
    source: 'stub',
  });
});

// GET /api/mes/dispatch/orders/:orderId — статус конкретного заказа
app.get('/api/mes/dispatch/orders/:orderId', (req, res) => {
  res.json({
    orderId: req.params.orderId,
    status: 'in_production',
    batchId: 'B-001',
    updatedAt: new Date().toISOString(),
    source: 'stub',
  });
});

// POST /api/mes/dispatch/orders/:orderId/status — обновление статуса заказа
app.post('/api/mes/dispatch/orders/:orderId/status', (req, res) => {
  res.status(202).json({
    orderId: req.params.orderId,
    accepted: true,
    note: 'stub: изменение не сохраняется, только подтверждает контракт API',
  });
});

// служебный healthcheck для k8s liveness/readiness
app.get('/healthz', (_req, res) => res.status(200).send('ok'));

app.listen(PORT, () => {
  console.log(`MES stub listening on :${PORT}`);
});

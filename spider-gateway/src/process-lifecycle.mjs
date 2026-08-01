export function hasLostParent(originalParentPID, currentParentPID = process.ppid) {
  return currentParentPID === 1 || (originalParentPID > 1 && currentParentPID !== originalParentPID);
}

export function startParentWatchdog(onParentLost, intervalMs = 5_000) {
  const originalParentPID = process.ppid;
  let handlingLoss = false;
  const timer = setInterval(() => {
    if (handlingLoss || !hasLostParent(originalParentPID)) return;
    handlingLoss = true;
    Promise.resolve(onParentLost()).catch(() => {}).finally(() => process.exit(0));
  }, intervalMs);
  timer.unref();
  return () => clearInterval(timer);
}

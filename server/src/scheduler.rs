//! Command ordering is independent from the observed Linn state. RPCs acknowledge
//! gateway acceptance; the playback lane stays occupied until its fields settle.
use crate::{
    optimism::{Command, Prediction},
    pb::{PendingState, Playlist, StateSnapshot},
};
use std::{collections::VecDeque, time::Duration};
use tokio::time::Instant;

const MAX_WAITING: usize = 8;
pub const WAIT_LIMIT: Duration = Duration::from_secs(15);
const ACK_LIMIT: Duration = Duration::from_secs(5);
const SETTLE_LIMIT: Duration = Duration::from_secs(3);
const MEDIA_SETTLE_LIMIT: Duration = Duration::from_secs(6);

struct Queued<T> {
    tag: String,
    command: Command,
    payload: T,
    expires: Instant,
    queue: Option<Playlist>,
    depends_on: Option<String>,
}
struct Active {
    tag: String,
    command: Command,
    prediction: Prediction,
    acknowledged: bool,
    expires: Instant,
}
struct Lane<T> {
    active: Option<Active>,
    waiting: VecDeque<Queued<T>>,
}
impl<T> Default for Lane<T> {
    fn default() -> Self {
        Self {
            active: None,
            waiting: VecDeque::new(),
        }
    }
}

pub struct Scheduler<T> {
    // Playback, volume, mute. Scope is carried by the wire request.
    lanes: [Lane<T>; 3],
    completed: Vec<(T, Result<(), tonic::Status>)>,
    refreshing: bool,
}
impl<T> Default for Scheduler<T> {
    fn default() -> Self {
        Self {
            lanes: std::array::from_fn(|_| Lane::default()),
            completed: Vec::new(),
            refreshing: false,
        }
    }
}

fn lane(command: &Command) -> usize {
    match command {
        Command::Volume(..) => 1,
        Command::Mute(..) => 2,
        _ => 0,
    }
}

// Coalesce only adjacent compatible intentions. Crossing another operation
// could discard a dependency (album -> pause, selection -> seek, two additions).
fn replaces(new: &Command, old: &Command) -> bool {
    matches!(
        (new, old),
        (Command::Select(_), Command::Select(_))
            | (Command::Seek(_), Command::Seek(_))
            | (Command::Transport(_), Command::Transport(_))
            | (Command::Volume(..), Command::Volume(..))
            | (Command::Mute(..), Command::Mute(..))
    ) || (new.replaces_queue() && old.replaces_queue())
}

impl<T> Scheduler<T> {
    pub fn enqueue(
        &mut self,
        tag: String,
        command: Command,
        payload: T,
        observed: &StateSnapshot,
        now: Instant,
    ) {
        let effective = self.snapshot(observed);
        // Linn revisions advance on selection updates too. Compare queue
        // contents, not revision numbers, when validating a waiting row/seek.
        let queue = matches!(command, Command::Select(_) | Command::Seek(_))
            .then(|| {
                effective
                    .now_playing
                    .as_ref()
                    .and_then(|p| p.playlist.clone())
            })
            .flatten()
            .filter(|_| !effective.pending.as_ref().is_some_and(|p| p.queue_total));
        let lane = &mut self.lanes[lane(&command)];
        if let Some(old) = lane
            .waiting
            .pop_back_if(|old| replaces(&command, &old.command))
        {
            self.completed.push((
                old.payload,
                Err(crate::error::with_reason(
                    tonic::Code::Cancelled,
                    "superseded",
                    "superseded by a newer value",
                )),
            ));
        }
        if lane.waiting.len() == MAX_WAITING {
            self.completed.push((
                payload,
                Err(tonic::Status::resource_exhausted(
                    "Linn control queue is full",
                )),
            ));
            return;
        }
        let depends_on = lane
            .waiting
            .iter()
            .rev()
            .map(|q| (&q.tag, &q.command))
            .chain(lane.active.iter().map(|a| (&a.tag, &a.command)))
            .find(|(_, prior)| match command {
                Command::Seek(_) => prior.changes_track(),
                Command::Select(_) | Command::Skip => prior.replaces_queue(),
                _ => false,
            })
            .map(|(tag, _)| tag.clone());
        lane.waiting.push_back(Queued {
            tag,
            command,
            payload,
            expires: now + WAIT_LIMIT,
            queue,
            depends_on,
        });
    }

    pub fn dispatch(&mut self, observed: &StateSnapshot, now: Instant) -> Vec<(String, T)> {
        let mut ready = Vec::new();
        for (index, lane) in self.lanes.iter_mut().enumerate() {
            if index == 0 && self.refreshing {
                continue;
            }
            // Volume/mute retain latest-value-wins after ack. Their old prediction
            // is replaced permanently when the next value is dispatched.
            if lane
                .active
                .as_ref()
                .is_some_and(|a| index == 0 || !a.acknowledged)
            {
                continue;
            }
            while let Some(next) = lane.waiting.pop_front() {
                if next.expires <= now {
                    self.completed.push((
                        next.payload,
                        Err(tonic::Status::deadline_exceeded(
                            "Linn command expired before dispatch",
                        )),
                    ));
                    cancel_dependents(lane, &next.tag, &mut self.completed);
                    continue;
                }
                if let Some(error) = validate(&next.command, next.queue.as_ref(), observed) {
                    self.completed.push((next.payload, Err(error)));
                    cancel_dependents(lane, &next.tag, &mut self.completed);
                    continue;
                }
                lane.active = Some(Active {
                    tag: next.tag.clone(),
                    prediction: Prediction::new(&next.command, observed),
                    command: next.command,
                    acknowledged: false,
                    expires: now + ACK_LIMIT,
                });
                ready.push((next.tag, next.payload));
                break;
            }
        }
        ready
    }

    pub fn acknowledge(&mut self, tag: &str, now: Instant) {
        for index in 0..self.lanes.len() {
            if let Some(active) = &mut self.lanes[index].active
                && active.tag == tag
            {
                active.acknowledged = true;
                active.expires = now
                    + if matches!(active.command, Command::Media { .. }) {
                        MEDIA_SETTLE_LIMIT
                    } else {
                        SETTLE_LIMIT
                    };
                if active.prediction.settled() {
                    self.finish(index, true);
                }
                break;
            }
        }
    }

    pub fn observe(&mut self, path: &str, observed: &StateSnapshot) {
        for index in 0..self.lanes.len() {
            if let Some(active) = &mut self.lanes[index].active {
                active.prediction.observe(path, observed);
                if active.acknowledged && active.prediction.settled() {
                    self.finish(index, true);
                }
            }
        }
    }

    pub fn reject(&mut self, tag: &str) {
        if let Some(index) = self
            .lanes
            .iter()
            .position(|lane| lane.active.as_ref().is_some_and(|a| a.tag == tag))
        {
            self.finish(index, false);
        }
    }

    fn finish(&mut self, index: usize, success: bool) {
        let lane = &mut self.lanes[index];
        let Some(active) = lane.active.take() else {
            return;
        };
        if success {
            // A -> B -> A has one actual selection. Do not restart A after it settles.
            if matches!(active.command, Command::Select(_))
                && lane
                    .waiting
                    .front()
                    .is_some_and(|next| next.command == active.command)
            {
                self.completed
                    .push((lane.waiting.pop_front().unwrap().payload, Ok(())));
            }
        } else {
            cancel_dependents(lane, &active.tag, &mut self.completed);
        }
    }

    /// Returns true once when playback needs a bounded read-back before dispatch.
    pub fn tick(&mut self, now: Instant) -> bool {
        let mut refresh = false;
        for index in 0..self.lanes.len() {
            if self.lanes[index]
                .active
                .as_ref()
                .is_some_and(|a| a.expires <= now)
            {
                self.finish(index, false);
                if index == 0 {
                    self.refreshing = true;
                    refresh = true;
                }
            }
            let lane = &mut self.lanes[index];
            let mut retained = VecDeque::new();
            let mut expired = Vec::new();
            for queued in lane.waiting.drain(..) {
                if queued.expires <= now {
                    expired.push(queued.tag.clone());
                    self.completed.push((
                        queued.payload,
                        Err(tonic::Status::deadline_exceeded(
                            "Linn command expired before dispatch",
                        )),
                    ));
                } else {
                    retained.push_back(queued);
                }
            }
            lane.waiting = retained;
            for tag in expired {
                cancel_dependents(lane, &tag, &mut self.completed);
            }
        }
        refresh
    }

    pub fn refreshed(&mut self) {
        self.refreshing = false;
    }
    pub fn take_completed(&mut self) -> Vec<(T, Result<(), tonic::Status>)> {
        std::mem::take(&mut self.completed)
    }
    pub fn clear(&mut self) {
        for lane in &mut self.lanes {
            lane.active = None;
            for next in lane.waiting.drain(..) {
                self.completed.push((
                    next.payload,
                    Err(crate::error::failed_precondition(
                        "linn-standby",
                        "Linn is in standby",
                    )),
                ));
            }
        }
        self.refreshing = false;
    }

    pub fn snapshot(&self, observed: &StateSnapshot) -> StateSnapshot {
        let mut snapshot = observed.clone();
        snapshot.pending = Some(PendingState::default());
        for lane in &self.lanes {
            if let Some(active) = &lane.active {
                active.prediction.project(&mut snapshot);
            }
            for queued in &lane.waiting {
                // Waiting projections are recomputed from preceding intentions;
                // their confirmation baseline is captured only at dispatch.
                Prediction::new(&queued.command, &snapshot).project(&mut snapshot);
            }
        }
        snapshot
    }
}

fn cancel_dependents<T>(
    lane: &mut Lane<T>,
    failed: &str,
    completed: &mut Vec<(T, Result<(), tonic::Status>)>,
) {
    let mut failed = vec![failed.to_owned()];
    let mut retained = VecDeque::new();
    for next in lane.waiting.drain(..) {
        if next
            .depends_on
            .as_ref()
            .is_some_and(|tag| failed.contains(tag))
        {
            failed.push(next.tag);
            completed.push((
                next.payload,
                Err(crate::error::failed_precondition(
                    "command-dependency",
                    "The preceding track or queue change did not settle",
                )),
            ));
        } else {
            retained.push_back(next);
        }
    }
    lane.waiting = retained;
}

fn validate(
    command: &Command,
    queue: Option<&Playlist>,
    observed: &StateSnapshot,
) -> Option<tonic::Status> {
    let playing = observed.now_playing.as_ref()?;
    if queue.is_some_and(|before| {
        playing.playlist.as_ref().is_none_or(|after| {
            before.total != after.total
                || before
                    .items
                    .iter()
                    .map(|i| (i.index, &i.display_name, &i.album, &i.artist))
                    .ne(after
                        .items
                        .iter()
                        .map(|i| (i.index, &i.display_name, &i.album, &i.artist)))
        })
    }) {
        return Some(crate::error::failed_precondition(
            "queue-changed",
            "The playlist changed before the command was sent",
        ));
    }
    if let Command::Select(index) = command
        && (*index < 0
            || playing
                .playlist
                .as_ref()
                .and_then(|q| q.total)
                .is_some_and(|n| *index >= n))
    {
        return Some(tonic::Status::out_of_range(
            "Playlist row is no longer available",
        ));
    }
    if let Command::Seek(position) = command
        && (*position < 0
            || playing.timeline.is_some_and(|t| {
                t.is_seekable == Some(false)
                    || t.duration_seconds.is_some_and(|d| d > 0 && *position > d)
            }))
    {
        return Some(tonic::Status::out_of_range(
            "Seek position is no longer available",
        ));
    }
    None
}

#[cfg(test)]
#[path = "scheduler_tests.rs"]
mod tests;

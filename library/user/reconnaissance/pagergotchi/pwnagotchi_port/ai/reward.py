"""
Reward function stub for Pagergotchi
The AI has been removed from pwnagotchi, so this is just a simple reward calculation
"""


class RewardFunction:
    """Simple reward calculation (no AI)"""

    def __init__(self):
        pass

    def __call__(self, epoch, epoch_data):
        """
        Calculate a simple reward based on epoch activity

        Higher is better:
        - Handshakes are very good (+10 each)
        - Deauths are good (+1 each)
        - Associations are good (+1 each)
        - Being inactive is bad (-1 per inactive epoch)
        """
        reward = 0.0

        # Reward handshakes heavily
        reward += epoch_data.get('num_handshakes', 0) * 10.0

        # Reward activity
        reward += epoch_data.get('num_deauths', 0) * 1.0
        reward += epoch_data.get('num_associations', 0) * 1.0

        # Penalize inactivity
        reward -= epoch_data.get('inactive_for_epochs', 0) * 1.0

        return round(reward, 2)

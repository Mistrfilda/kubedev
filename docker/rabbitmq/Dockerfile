FROM rabbitmq:management

RUN rabbitmq-plugins enable --offline rabbitmq_mqtt rabbitmq_web_mqtt

ENV RABBITMQ_DEFAULT_USER=appuser
ENV RABBITMQ_DEFAULT_PASS=extremelysecretrabbit

EXPOSE 5672 15672
